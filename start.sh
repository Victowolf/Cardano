#!/usr/bin/env bash
set -euo pipefail


BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$BASE_DIR/scripts"
CONFIG_DIR="$BASE_DIR/config"


echo "Starting Cardano private single-node bootstrap..."


# Ensure helper scripts are executable
chmod +x "$SCRIPTS_DIR"/*.sh


# 1) Create genesis files and protocol config
bash "$SCRIPTS_DIR/create-genesis.sh" "$CONFIG_DIR"


# 2) Create keys and payment address
bash "$SCRIPTS_DIR/create-keys.sh" "$CONFIG_DIR"


# 3) Start the node in background and tail logs
bash "$SCRIPTS_DIR/start-node.sh" "$CONFIG_DIR"


# Keep the container/pod running by tailing node.log
NODE_LOG="$BASE_DIR/node.log"
if [ -f "$NODE_LOG" ]; then
echo "Tailing $NODE_LOG"
tail -n +1 -f "$NODE_LOG"
else
echo "Node log not found at $NODE_LOG. Sleeping indefinitely to keep pod alive."
sleep infinity
fi