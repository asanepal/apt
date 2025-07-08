#!/bin/bash
set -euo pipefail

# === Config ===
IMAGE_NAME="cloudflare/cloudflared:latest"
CONTAINER_NAME="cloudfared"
TOKEN_FILE="/etc/cloudflared/token.txt"

BROKER_IMAGE_NAME="your/broker-image:latest"
BROKER_CONTAINER_NAME="broker"

UPDATE_INTERVAL_SECONDS=3600
SELF_UPDATE_URL="https://raw.githubusercontent.com/your-org/your-repo/main/housekeeper.sh"
INSTALL_PATH="/usr/local/bin/housekeeper.sh"
SERVICE_FILE="/etc/systemd/system/housekeeper.service"

PORT_CONFIG_URL="https://raw.githubusercontent.com/your-org/your-repo/main/port_mappings.conf"
PORT_MAPPINGS_FILE="/tmp/port_mappings.conf"
DOCKER_PORT_ARGS=""
PORTS_TO_FREE=""

# === Ensure Docker socket ===
if [ -S "/var/run/docker.sock" ]; then
  export DOCKER_HOST=unix:///var/run/docker.sock
else
  echo "[!] Docker socket not found at /var/run/docker.sock" >&2
  exit 1
fi

# === Accept Tunnel Token only for first time setup ===
if [ ! -f "$TOKEN_FILE" ]; then
  if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <tunnel-token> (required only on first run)"
    exit 1
  fi
  TUNNEL_TOKEN="$1"
  mkdir -p "$(dirname \"$TOKEN_FILE\")"
  echo "$TUNNEL_TOKEN" > "$TOKEN_FILE"
  chown root:root "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
fi

function fetch_and_run_latest_script() {
  TMP_SCRIPT=$(mktemp)
  echo "[*] Fetching latest housekeeper script from GitHub..."
  curl -fsSL "$SELF_UPDATE_URL" -o "$TMP_SCRIPT"

  if ! cmp -s "$TMP_SCRIPT" "$0"; then
    echo "[+] Newer version detected. Executing updated script."
    chmod +x "$TMP_SCRIPT"
    exec "$TMP_SCRIPT" "$@"
  else
    echo "[*] Running current script version."
    rm "$TMP_SCRIPT"
  fi
}

# === Always check for latest script ===
fetch_and_run_latest_script "$@"

function install_self() {
  if [ ! -f "$INSTALL_PATH" ] || ! cmp -s "$0" "$INSTALL_PATH"; then
    echo "[*] Installing script to $INSTALL_PATH"
    mkdir -p "$(dirname \"$INSTALL_PATH\")"
    cp "$0" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
  fi
}

function create_systemd_service() {
  echo "[*] Creating systemd service..."
  TMP_UNIT=$(mktemp)
[Unit]
Description=Housekeeper Docker Tunnel Updater
After=docker.service
Requires=docker.service

[Service]
ExecStart=$INSTALL_PATH
Restart=always
RestartSec=30
SyslogIdentifier=housekeeper

[Install]
WantedBy=multi-user.target
EOF

  if ! cmp -s "$TMP_UNIT" "$SERVICE_FILE"; then
    echo "[+] Updating systemd service file and reloading..."
    mv "$TMP_UNIT" "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable housekeeper.service
    systemctl restart housekeeper.service
    echo "[*] housekeeper.service started and enabled."
  else
    echo "[*] Systemd service file unchanged. Skipping reload."
    rm "$TMP_UNIT"
  fi
}

function disable_journald_persistence() {
  echo "[*] Disabling journald persistent storage"
  mkdir -p /etc/systemd/journald.conf.d
  echo -e "[Journal]\nStorage=volatile" > /etc/systemd/journald.conf.d/volatile.conf
  systemctl restart systemd-journald || true
}

function disable_firewall() {
  if command -v ufw &>/dev/null; then
    echo "[*] Disabling ufw firewall"
    ufw disable || true
  else
    echo "[*] Flushing iptables firewall rules"
    iptables -F || true
  fi
}

function install_required_packages() {
  echo "[*] Installing required packages"
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    cloud-init open-vm-tools docker.io
}

function fetch_port_mappings() {
  echo "[*] Fetching port mappings from GitHub..."
  curl -fsSL "$PORT_CONFIG_URL" -o "$PORT_MAPPINGS_FILE"

  DOCKER_PORT_ARGS=""
  PORTS_TO_FREE=""

  while IFS= read -r line || [ -n "$line" ]; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue

    if [[ "$line" =~ ^([0-9]+):([0-9]+)$ ]]; then
      host_port="${BASH_REMATCH[1]}"
      PORTS_TO_FREE+=" $host_port"
      DOCKER_PORT_ARGS+=" -p $line"
    else
      echo "[!] Invalid port mapping line: $line"
    fi
  done < "$PORT_MAPPINGS_FILE"
}

function free_ports() {
  for port in $@; do
    PID=$(lsof -iTCP:$port -sTCP:LISTEN -t || true)
    if [ -n "$PID" ]; then
      echo "[*] Port $port is in use by PID $PID."
      CONTAINER_IDS=$(docker ps --format '{{.ID}} {{.Names}} {{.Ports}}' | grep ":$port->" | awk '{print $1,$2}' || true)
      if [ -n "$CONTAINER_IDS" ]; then
        while read -r cid cname; do
          if [[ "$cname" != "$CONTAINER_NAME" && "$cname" != "$BROKER_CONTAINER_NAME" ]]; then
            echo "[*] Stopping Docker container $cid ($cname) using port $port..."
            docker stop "$cid" || true
            docker rm "$cid" || true
          else
            echo "[*] Allowed container $cname is using port $port, skipping."
          fi
        done <<< "$CONTAINER_IDS"
      else
        echo "[*] Port $port used by non-Docker process PID $PID. Killing it..."
        kill -9 "$PID" || echo "[!] Failed to kill PID $PID"
      fi
    else
      echo "[*] Port $port is free."
    fi
  done
}

function run_cloudfared() {
  docker run -d --name "$CONTAINER_NAME" --restart unless-stopped \
    -v /etc/cloudflared:/etc/cloudflared:ro \
    "$IMAGE_NAME" tunnel run --no-autoupdate --token "$(cat "$TOKEN_FILE")"
}

function run_broker() {
  docker run -d --name "$BROKER_CONTAINER_NAME" --restart unless-stopped \
    $DOCKER_PORT_ARGS \
    "$BROKER_IMAGE_NAME"
}

function update_container() {
  echo "[*] Checking for image updates for cloudfared..."
  if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    echo "[!] Cloudflared image not found locally. Pulling it..."
    docker pull "$IMAGE_NAME"
  fi

  if docker pull "$IMAGE_NAME" | grep -q 'Downloaded newer image'; then
    echo "[+] New cloudfared image found. Restarting container."
    docker stop "$CONTAINER_NAME" || true
    docker rm "$CONTAINER_NAME" || true
    run_cloudfared
  elif ! docker ps --format '{{.Names}}' | grep -qw "$CONTAINER_NAME"; then
    echo "[*] Cloudfared container not running. Starting..."
    run_cloudfared
  else
    echo "[*] cloudfared image is up to date."
  fi
}

function ensure_container_running() {
  if ! docker ps --format '{{.Names}}' | grep -qw "$CONTAINER_NAME"; then
    echo "[*] Container $CONTAINER_NAME not running. Restarting..."
    run_cloudfared
  fi
}

function check_broker_ports_and_recover() {
  fetch_port_mappings
  for port in $PORTS_TO_FREE; do
    PID=$(lsof -iTCP:$port -sTCP:LISTEN -t || true)
    if [ -n "$PID" ]; then
      CONTAINER_NAME_USING_PORT=$(docker ps --format '{{.ID}} {{.Names}} {{.Ports}}' | grep ":$port->" | awk '{print $2}' || true)
      if [[ "$CONTAINER_NAME_USING_PORT" != "$BROKER_CONTAINER_NAME" ]]; then
        echo "[*] Port $port is not available to broker. Restarting broker after freeing ports."
        free_ports $PORTS_TO_FREE
        docker stop "$BROKER_CONTAINER_NAME" || true
        docker rm "$BROKER_CONTAINER_NAME" || true
        run_broker
        return
      fi
    fi
  done
}

function update_broker() {
  echo "[*] Checking for image updates for broker..."
  if docker pull "$BROKER_IMAGE_NAME" | grep -q 'Downloaded newer image'; then
    echo "[+] New broker image found. Freeing ports and restarting container."
    fetch_port_mappings
    free_ports $PORTS_TO_FREE
    docker stop "$BROKER_CONTAINER_NAME" || true
    docker rm "$BROKER_CONTAINER_NAME" || true
    run_broker
  else
    echo "[*] broker image is up to date."
  fi
}

function ensure_broker_running() {
  if ! docker ps --format '{{.Names}}' | grep -qw "$BROKER_CONTAINER_NAME"; then
    echo "[*] Broker container not running. Freeing ports and starting container..."
    fetch_port_mappings
    free_ports $PORTS_TO_FREE
    run_broker
  else
    check_broker_ports_and_recover
  fi
}

# === One-Time Setup ===
disable_journald_persistence
disable_firewall
install_required_packages
install_self
create_systemd_service

# === Main loop ===
while true; do
  fetch_and_run_latest_script "$@"
  disable_journald_persistence
  disable_firewall
  update_container
  ensure_container_running
  update_broker
  ensure_broker_running
  sleep "$UPDATE_INTERVAL_SECONDS"
done
