#!/usr/bin/env bash
set -euo pipefail


# Common variables
CARDANO_CLI_BIN="cardano-cli"
CARDANO_NODE_BIN="cardano-node"
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NODE_SOCKET_PATH="$BASE_DIR/db/node.socket"
NETWORK_MAGIC=42


# helper: ensure command exists
require_cmd() {
command -v "$1" >/dev/null 2>&1 || { echo "ERROR: required command $1 not found in PATH" >&2; exit 1; }
}


require_cmd "$CARDANO_CLI_BIN"
require_cmd "$CARDANO_NODE_BIN"


mkdir -p "$BASE_DIR/db"