#!/usr/bin/env bash
set -euo pipefail

CARDANO_VERSION="10.1.4"
TARBALL="cardano-node-${CARDANO_VERSION}-linux.tar.gz"
RELEASE_URL="https://github.com/IntersectMBO/cardano-node/releases/download/${CARDANO_VERSION}/${TARBALL}"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RAW_CONFIG_DIR="$BASE_DIR/config_raw"
RUN_CONFIG_DIR="$BASE_DIR/config"
DB_DIR="$BASE_DIR/db"
KEYS_DIR="$BASE_DIR/keys"

rm -rf "$RAW_CONFIG_DIR" "$RUN_CONFIG_DIR" "$DB_DIR" "$KEYS_DIR"
mkdir -p "$RAW_CONFIG_DIR" "$RUN_CONFIG_DIR" "$DB_DIR" "$KEYS_DIR"

############################################################
# DOWNLOAD BINARIES
############################################################

if ! command -v cardano-node >/dev/null 2>&1; then
    echo ">>> Downloading Cardano Node ${CARDANO_VERSION}"
    wget -q "$RELEASE_URL" -O "$TARBALL"
    tar -xf "$TARBALL"

    mv bin/cardano-node /usr/local/bin/
    mv bin/cardano-cli  /usr/local/bin/

    cp -r share/sanchonet/* "$RAW_CONFIG_DIR/"

    rm -rf bin lib share "$TARBALL"
fi

############################################################
# COPY REQUIRED FILES
############################################################

cp "$RAW_CONFIG_DIR/config.json" "$RUN_CONFIG_DIR/"
cp "$RAW_CONFIG_DIR/topology.json" "$RUN_CONFIG_DIR/"
cp "$RAW_CONFIG_DIR/byron-genesis.json" "$RUN_CONFIG_DIR/"
cp "$RAW_CONFIG_DIR/shelley-genesis.json" "$RUN_CONFIG_DIR/"
cp "$RAW_CONFIG_DIR/alonzo-genesis.json" "$RUN_CONFIG_DIR/"
cp "$RAW_CONFIG_DIR/conway-genesis.json" "$RUN_CONFIG_DIR/"

############################################################
# GENERATE WALLET
############################################################

cardano-cli address key-gen \
  --verification-key-file "$KEYS_DIR/payment.vkey" \
  --signing-key-file "$KEYS_DIR/payment.skey"

# Build address (for your usage later)
cardano-cli address build \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey" \
  --testnet-magic 4 \
  > "$KEYS_DIR/payment.addr"

ADDRESS=$(cat "$KEYS_DIR/payment.addr")

echo "Bech32 address: $ADDRESS"

# Get payment key HASH (THIS is what goes into genesis)
PAYMENT_HASH=$(cardano-cli address key-hash \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey")

echo "Payment key hash: $PAYMENT_HASH"

############################################################
# UPDATE SHELLEY GENESIS WITH KEY HASH
############################################################

jq ".initialFunds += {\"$PAYMENT_HASH\": {\"lovelace\": 1000000000000}}" \
   "$RUN_CONFIG_DIR/shelley-genesis.json" > "$RUN_CONFIG_DIR/tmp.json"

mv "$RUN_CONFIG_DIR/tmp.json" "$RUN_CONFIG_DIR/shelley-genesis.json"

############################################################
# TRUE BLAKE2b HASH FOR SHELLEY GENESIS
############################################################

compute_hash() {
  local f="$1"

  cardano-cli conway genesis hash --genesis "$f"        2>/dev/null && return 0
  cardano-cli genesis hash --genesis "$f"               2>/dev/null && return 0
  cardano-cli shelley genesis hash --genesis "$f"       2>/dev/null && return 0
  cardano-cli genesis hash --shelley-genesis-file "$f"  2>/dev/null && return 0
  cardano-cli governance hash --file "$f"               2>/dev/null && return 0

  return 1
}

echo ">>> Computing correct BLAKE2b Shelley genesis hash..."
if ! NEW_HASH=$(compute_hash "$RUN_CONFIG_DIR/shelley-genesis.json"); then
  echo "ERROR: Could not compute Shelley hash."
  exit 1
fi

echo "Correct ShelleyGenesisHash: $NEW_HASH"

############################################################
# PATCH CONFIG.JSON
############################################################

jq ".ShelleyGenesisHash = \"$NEW_HASH\"" \
   "$RUN_CONFIG_DIR/config.json" > "$RUN_CONFIG_DIR/tmp.json"

mv "$RUN_CONFIG_DIR/tmp.json" "$RUN_CONFIG_DIR/config.json"

############################################################
# START NODE
############################################################

echo ">>> Starting cardano-node..."

cardano-node run \
  --topology "$RUN_CONFIG_DIR/topology.json" \
  --database-path "$DB_DIR" \
  --socket-path "$DB_DIR/node.socket" \
  --host-addr 0.0.0.0 \
  --port 3001 \
  --config "$RUN_CONFIG_DIR/config.json" \
  > "$BASE_DIR/node.log" 2>&1 &

echo ""
echo "==============================="
echo "   SANCHONET NODE STARTED"
echo "==============================="
echo "Address (Bech32): $ADDRESS"
echo "Payment Key Hash: $PAYMENT_HASH"
echo "Logs: $BASE_DIR/node.log"
echo ""

tail -f "$BASE_DIR/node.log"
