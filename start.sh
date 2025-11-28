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

echo ">>> Extracted official Sanchonet configs"

############################################################
# COPY NECESSARY CONFIG FILES
############################################################
cp "$RAW_CONFIG_DIR/config.json"          "$RUN_CONFIG_DIR/"
cp "$RAW_CONFIG_DIR/topology.json"        "$RUN_CONFIG_DIR/"
cp "$RAW_CONFIG_DIR/byron-genesis.json"   "$RUN_CONFIG_DIR/"
cp "$RAW_CONFIG_DIR/shelley-genesis.json" "$RUN_CONFIG_DIR/"
cp "$RAW_CONFIG_DIR/alonzo-genesis.json"  "$RUN_CONFIG_DIR/"
cp "$RAW_CONFIG_DIR/conway-genesis.json"  "$RUN_CONFIG_DIR/"

echo ">>> Clean config generated in /app/config"

############################################################
# GENERATE WALLET (BECH32)
############################################################
echo ">>> Generating wallet keys"

cardano-cli address key-gen \
  --verification-key-file "$KEYS_DIR/payment.vkey" \
  --signing-key-file      "$KEYS_DIR/payment.skey"

cardano-cli address build \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey" \
  --testnet-magic 4 \
  --out-file "$KEYS_DIR/payment.addr.bech32"

BECH32_ADDR=$(cat "$KEYS_DIR/payment.addr.bech32")
echo "Bech32 Address (human readable): $BECH32_ADDR"

############################################################
# CONVERT BECH32 → RAW HEX FOR GENESIS
############################################################
echo ">>> Converting bech32 → hex (genesis-compatible address)"

RAW_ADDR=$(cardano-cli address info --address "$BECH32_ADDR" \
           | jq -r '.base16')

if [ -z "$RAW_ADDR" ] || ! echo "$RAW_ADDR" | grep -Eq '^[0-9a-f]+$'; then
    echo "❌ ERROR: cardano-cli failed to produce valid hex address"
    echo "cardano-cli output:"
    cardano-cli address info --address "$BECH32_ADDR"
    exit 1
fi

echo "RAW HEX Address for genesis: $RAW_ADDR"

############################################################
# UPDATE SHELLEY GENESIS WITH INITIAL FUNDS (HEX ADDRESS)
############################################################
echo ">>> Adding initial funds to shelley-genesis.json"

jq ".initialFunds += {\"$RAW_ADDR\": {\"lovelace\": 1000000000000}}" \
   "$RUN_CONFIG_DIR/shelley-genesis.json" \
   > "$RUN_CONFIG_DIR/tmp.json"

mv "$RUN_CONFIG_DIR/tmp.json" "$RUN_CONFIG_DIR/shelley-genesis.json"

############################################################
# COMPUTE BLAKE2b GENESIS HASH (REQUIRED)
############################################################
echo ">>> Computing correct BLAKE2b Shelley Genesis Hash"

NEW_HASH=$(cardano-cli genesis hash --shelley-genesis-file "$RUN_CONFIG_DIR/shelley-genesis.json")

if [ -z "$NEW_HASH" ]; then
    echo "❌ ERROR: Could not compute Shelley genesis hash"
    exit 1
fi

echo "Correct ShelleyGenesisHash = $NEW_HASH"

############################################################
# PATCH CONFIG.JSON
############################################################
echo ">>> Patching config.json with new ShelleyGenesisHash"

jq ".ShelleyGenesisHash = \"$NEW_HASH\"" \
   "$RUN_CONFIG_DIR/config.json" \
   > "$RUN_CONFIG_DIR/tmp.json"

mv "$RUN_CONFIG_DIR/tmp.json" "$RUN_CONFIG_DIR/config.json"

echo ">>> FINAL config.json:"
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
echo "================================="
echo "     SANCHONET NODE STARTED       "
echo "================================="
echo "Wallet (BECH32): $BECH32_ADDR"
echo "Wallet (HEX):    $RAW_ADDR"
echo "Logs:            $BASE_DIR/node.log"
echo ""

tail -f "$BASE_DIR/node.log"
