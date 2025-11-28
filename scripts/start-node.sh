#!/usr/bin/env bash
set -euo pipefail


CONFIG_DIR="${1:-$(pwd)/config}"
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DB_DIR="$BASE_DIR/db"
LOG_FILE="$BASE_DIR/node.log"
GENESIS="$BASE_DIR/genesis.json"
NODE_CONFIG="$CONFIG_DIR/node-config.json"
TOPOLOGY="$CONFIG_DIR/topology.json"


mkdir -p "$DB_DIR"


# basic run - replace --SocketPath and ports as you need
cardano-node run \
--topology "$TOPOLOGY" \
--database-path "$DB_DIR" \
--socket-path "$DB_DIR/node.socket" \
--host-addr 0.0.0.0 \
--port 3001 \
--config "$NODE_CONFIG" \
> "$LOG_FILE" 2>&1 &


echo "cardano-node started, logging to $LOG_FILE"