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
# DOWNLOAD BINARIES + OFFICIAL SANCHONET CONFIGS
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
# COPY CLEAN SANCHONET CONFIGS
############################################################

cp "$RAW_CONFIG_DIR/config.json"          "$RUN_CONFIG_DIR/"
cp "$RAW_CONFIG_DIR/topology.json"        "$RUN_CONFIG_DIR/"
cp "$RAW_CONFIG_DIR/byron-genesis.json"   "$RUN_CONFIG_DIR/"
cp "$RAW_CONFIG_DIR/shelley-genesis.json" "$RUN_CONFIG_DIR/"
cp "$RAW_CONFIG_DIR/alonzo-genesis.json"  "$RUN_CONFIG_DIR/"
cp "$RAW_CONFIG_DIR/conway-genesis.json"  "$RUN_CONFIG_DIR/"

############################################################
# GENERATE WALLET + GENESIS-FRIENDLY HEX ADDRESS
############################################################

cardano-cli address key-gen \
  --verification-key-file "$KEYS_DIR/payment.vkey" \
  --signing-key-file "$KEYS_DIR/payment.skey"

# Bech32 human readable address
BECH32_ADDR=$(cardano-cli address build \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey" \
  --testnet-magic 4)

echo "Funding address (bech32): $BECH32_ADDR"

# HEX address required by genesis initialFunds
# Convert vkey -> payment keyhash
KEYHASH=$(cardano-cli address key-hash \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey")

# Use cardano-address to build hex Shelley address
GENESIS_HEX=$(echo $KEYHASH | \
  cardano-address address payment \
    --network-tag testnet \
  | cardano-address address inspect \
  | jq -r '.address_hex')

echo "Genesis HEX: $GENESIS_HEX"


############################################################
# ADD INITIAL FUNDS USING HEX ADDRESS (REQUIRED)
############################################################

jq ".initialFunds += {\"$GENESIS_HEX\": {\"lovelace\": 1000000000000}}" \
   "$RUN_CONFIG_DIR/shelley-genesis.json" > "$RUN_CONFIG_DIR/tmp.json"

mv "$RUN_CONFIG_DIR/tmp.json" "$RUN_CONFIG_DIR/shelley-genesis.json"

############################################################
# COMPUTE CORRECT GENESIS HASH
############################################################

echo ">>> Computing correct Shelley Genesis Hash..."
GENESIS_HASH=$(cardano-cli conway genesis hash \
  --genesis "$RUN_CONFIG_DIR/shelley-genesis.json")

echo "Correct ShelleyGenesisHash = $GENESIS_HASH"

############################################################
# PATCH INTO OFFICIAL CONFIG.JSON
############################################################

jq ".ShelleyGenesisHash = \"$GENESIS_HASH\"" \
   "$RUN_CONFIG_DIR/config.json" > "$RUN_CONFIG_DIR/tmp.json"

mv "$RUN_CONFIG_DIR/tmp.json" "$RUN_CONFIG_DIR/config.json"

echo ">>> FINAL CONFIG.JSON:"
cat "$RUN_CONFIG_DIR/config.json"

############################################################
# START NODE
############################################################

echo ">>> Starting cardano-node..."

cardano-node run \
  --topology      "$RUN_CONFIG_DIR/topology.json" \
  --database-path "$DB_DIR" \
  --socket-path   "$DB_DIR/node.socket" \
  --host-addr     0.0.0.0 \
  --port          3001 \
  --config        "$RUN_CONFIG_DIR/config.json" \
  > "$BASE_DIR/node.log" 2>&1 &

echo ""
echo "==============================="
echo "  PRIVATE SANCHONET NODE READY "
echo "==============================="
echo "Address (bech32): $BECH32_ADDR"
echo "Genesis HEX:      $GENESIS_HEX"
echo "Genesis Hash:     $GENESIS_HASH"
echo "Logs:             $BASE_DIR/node.log"
echo ""

tail -f "$BASE_DIR/node.log"
