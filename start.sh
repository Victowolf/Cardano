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

############################################################
# CLEAN DIRECTORIES
############################################################

rm -rf "$CONFIG_DIR" "$DB_DIR" "$KEYS_DIR"
mkdir -p "$CONFIG_DIR" "$DB_DIR" "$KEYS_DIR"

############################################################
# DOWNLOAD BINARIES
############################################################

if ! command -v cardano-node >/dev/null 2>&1; then
    echo ">>> Downloading Cardano Node ${CARDANO_VERSION}"
    wget -q "$RELEASE_URL" -O "$TARBALL"

    echo ">>> Extracting"
    tar -xf "$TARBALL"

    echo ">>> Installing binaries"
    mv bin/cardano-node "$BIN_DIR/"
    mv bin/cardano-cli "$BIN_DIR/"

    echo ">>> Copying official Sanchonet configs"
    cp -r share/sanchonet/* "$CONFIG_DIR/"

    echo ">>> Cleaning tarball files"
    rm -rf bin lib share "$TARBALL"
fi

############################################################
# GENERATE WALLET
############################################################

echo ">>> Generating wallet keys"

cardano-cli address key-gen \
  --verification-key-file "$KEYS_DIR/payment.vkey" \
  --signing-key-file "$KEYS_DIR/payment.skey"

echo ">>> Building address (testnet magic = 4)"
cardano-cli address build \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey" \
  --testnet-magic 4 \
  > "$KEYS_DIR/payment.addr"

ADDRESS=$(cat "$KEYS_DIR/payment.addr")

echo ">>> Funding address: $ADDRESS"

############################################################
# UPDATE SHELLEY GENESIS (ADD FUNDS)
############################################################

echo ">>> Adding initial funds to Shelley genesis"

jq ".initialFunds += {\"$ADDRESS\": {\"lovelace\": 1000000000000}}" \
   "$CONFIG_DIR/shelley-genesis.json" > "$CONFIG_DIR/tmp.json"

mv "$CONFIG_DIR/tmp.json" "$CONFIG_DIR/shelley-genesis.json"

############################################################
# UPDATE GENESIS HASH IN CONFIG.JSON
############################################################

echo ">>> Computing updated genesis hash"
NEW_HASH=$(cardano-cli governance genesis hash --genesis "$CONFIG_DIR/shelley-genesis.json")

echo ">>> Updating hash in config.json"
jq ".npcShelleyGenesisFileHash = \"$NEW_HASH\"" \
   "$CONFIG_DIR/config.json" > "$CONFIG_DIR/tmp.json"

mv "$CONFIG_DIR/tmp.json" "$CONFIG_DIR/config.json"

echo "New Shelley Genesis Hash = $NEW_HASH"

############################################################
# START NODE
############################################################

echo ">>> Starting cardano-node"

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
echo "Tailing logs..."
tail -f "$BASE_DIR/node.log"
