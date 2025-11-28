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

# HARD-CODED CBOR-HEX GENESIS ADDRESS (ALWAYS VALID)
HARDCODED_GENESIS_HEX="581d602f594c56aaed35e85b1bc4ce2dfab46f21e0c00ac2a9ae7cd27f"

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
# COPY SANCHONET CONFIG
############################################################

cp "$RAW_CONFIG_DIR/config.json" "$RUN_CONFIG_DIR/"
cp "$RAW_CONFIG_DIR/topology.json" "$RUN_CONFIG_DIR/"
cp "$RAW_CONFIG_DIR/byron-genesis.json" "$RUN_CONFIG_DIR/"
cp "$RAW_CONFIG_DIR/shelley-genesis.json" "$RUN_CONFIG_DIR/"
cp "$RAW_CONFIG_DIR/alonzo-genesis.json" "$RUN_CONFIG_DIR/"
cp "$RAW_CONFIG_DIR/conway-genesis.json" "$RUN_CONFIG_DIR/"

############################################################
# GENERATE PAYMENT KEYPAIR (just for user wallet)
############################################################

cardano-cli address key-gen \
  --verification-key-file "$KEYS_DIR/payment.vkey" \
  --signing-key-file "$KEYS_DIR/payment.skey"

cardano-cli address build \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey" \
  --testnet-magic 4 \
  > "$KEYS_DIR/payment.addr"

USER_ADDR=$(cat "$KEYS_DIR/payment.addr")
echo "Human Wallet Address: $USER_ADDR"

############################################################
# INSERT HARD-CODED INITIAL FUNDS
############################################################

jq ".initialFunds += {\"$HARDCODED_GENESIS_HEX\": {\"lovelace\": 1000000000000}}" \
   "$RUN_CONFIG_DIR/shelley-genesis.json" > "$RUN_CONFIG_DIR/tmp.json"

mv "$RUN_CONFIG_DIR/tmp.json" "$RUN_CONFIG_DIR/shelley-genesis.json"

############################################################
# COMPUTE GENESIS HASH
############################################################

GENESIS_HASH=$(cardano-cli conway genesis hash \
  --genesis "$RUN_CONFIG_DIR/shelley-genesis.json")

jq ".ShelleyGenesisHash = \"$GENESIS_HASH\"" \
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

sleep 2

echo ""
echo "==============================="
echo " PRIVATE SANCHONET NODE READY"
echo "==============================="
echo "User Wallet (Bech32): $USER_ADDR"
echo "Genesis HEX Funding Address: $HARDCODED_GENESIS_HEX"
echo "Genesis Hash: $GENESIS_HASH"
echo "Logs: $BASE_DIR/node.log"
echo ""

tail -f "$BASE_DIR/node.log"
