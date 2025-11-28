#!/usr/bin/env bash
set -euo pipefail

CARDANO_VERSION="10.1.4"
TARBALL="cardano-node-${CARDANO_VERSION}-linux.tar.gz"
RELEASE_URL="https://github.com/IntersectMBO/cardano-node/releases/download/${CARDANO_VERSION}/${TARBALL}"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$BASE_DIR/config"
DB_DIR="$BASE_DIR/db"
BIN_DIR="/usr/local/bin"
KEYS_DIR="$BASE_DIR/keys"

rm -rf "$CONFIG_DIR" "$DB_DIR"
mkdir -p "$CONFIG_DIR" "$DB_DIR" "$KEYS_DIR"

############################################################
# DOWNLOAD BINARIES
############################################################

if ! command -v cardano-node >/dev/null 2>&1; then
    wget -q "$RELEASE_URL" -O "$TARBALL"
    tar -xf "$TARBALL"

    mv bin/cardano-node "$BIN_DIR/"
    mv bin/cardano-cli "$BIN_DIR/"

    # Copy official Sanchonet configs
    cp -r share/sanchonet/* "$CONFIG_DIR/"

    rm -rf bin lib share "$TARBALL"
fi

############################################################
# GENERATE WALLET + FUND IT IN GENESIS
############################################################

cardano-cli address key-gen \
  --verification-key-file "$KEYS_DIR/payment.vkey" \
  --signing-key-file "$KEYS_DIR/payment.skey"

cardano-cli address build \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey" \
  --testnet-magic $(jq .protocolParams.protocolMagic "$CONFIG_DIR/shelley-genesis.json") \
  > "$KEYS_DIR/payment.addr"

ADDRESS=$(cat "$KEYS_DIR/payment.addr")

echo "Funding address: $ADDRESS"

# Add funds to shelley-genesis
jq ".initialFunds += {\"$ADDRESS\": {\"lovelace\": 1000000000000}}" \
   "$CONFIG_DIR/shelley-genesis.json" > "$CONFIG_DIR/tmp.json"

mv "$CONFIG_DIR/tmp.json" "$CONFIG_DIR/shelley-genesis.json"

############################################################
# START NODE
############################################################

cardano-node run \
  --topology "$CONFIG_DIR/topology.json" \
  --database-path "$DB_DIR" \
  --socket-path "$DB_DIR/node.socket" \
  --host-addr 0.0.0.0 \
  --port 3001 \
  --config "$CONFIG_DIR/config.json" \
  > "$BASE_DIR/node.log" 2>&1 &

echo ""
echo "=============================="
echo "  SANCHONET PRIVATE NODE READY"
echo "=============================="
echo "Address: $ADDRESS"
echo "Config: $CONFIG_DIR"
echo ""
tail -f "$BASE_DIR/node.log"
