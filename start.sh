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
    mv bin/cardano-cli /usr/local/bin/

    cp -r share/sanchonet/* "$RAW_CONFIG_DIR/"

    rm -rf bin lib share "$TARBALL"
fi

############################################################
# COPY REQUIRED FILES INTO CLEAN CONFIG DIR
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

cardano-cli address build \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey" \
  --testnet-magic 4 > "$KEYS_DIR/payment.addr"

ADDRESS=$(cat "$KEYS_DIR/payment.addr")
echo "Funding address: $ADDRESS"

############################################################
# UPDATE SHELLEY GENESIS
############################################################

jq ".initialFunds += {\"$ADDRESS\": {\"lovelace\": 1000000000000}}" \
  "$RUN_CONFIG_DIR/shelley-genesis.json" > "$RUN_CONFIG_DIR/tmp.json"
mv "$RUN_CONFIG_DIR/tmp.json" "$RUN_CONFIG_DIR/shelley-genesis.json"

############################################################
# COMPUTE NEW HASH (sha256sum is correct for shelley genesis)
############################################################

NEW_HASH=$(sha256sum "$RUN_CONFIG_DIR/shelley-genesis.json" | awk '{print $1}')
echo "Computed ShelleyGenesisHash = $NEW_HASH"

############################################################
# PATCH CORRECT FIELD IN config.json
############################################################

jq ".ShelleyGenesisHash = \"$NEW_HASH\"" \
  "$RUN_CONFIG_DIR/config.json" > "$RUN_CONFIG_DIR/tmp.json"

mv "$RUN_CONFIG_DIR/tmp.json" "$RUN_CONFIG_DIR/config.json"

echo ">>> FINAL PATCHED CONFIG.JSON:"
cat "$RUN_CONFIG_DIR/config.json"

############################################################
# START NODE
############################################################

echo ">>> Starting node..."

cardano-node run \
  --topology "$RUN_CONFIG_DIR/topology.json" \
  --database-path "$DB_DIR" \
  --socket-path "$DB_DIR/node.socket" \
  --host-addr 0.0.0.0 \
  --port 3001 \
  --config "$RUN_CONFIG_DIR/config.json" \
  > "$BASE_DIR/node.log" 2>&1 &

tail -f "$BASE_DIR/node.log"