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
# DOWNLOAD CARDANO BINARY RELEASE
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
# COPY SANCHONET RAW CONFIG INTO RUN CONFIG DIR
############################################################

cp "$RAW_CONFIG_DIR/"* "$RUN_CONFIG_DIR/"


############################################################
# GENERATE PAYMENT KEYS + BECH32 ADDRESS
############################################################

cardano-cli address key-gen \
  --verification-key-file "$KEYS_DIR/payment.vkey" \
  --signing-key-file "$KEYS_DIR/payment.skey"

ADDRESS=$(cardano-cli address build \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey" \
  --testnet-magic 4)

echo "Funding Address (bech32): $ADDRESS"


############################################################
# BUILD CBOR-ENCODED GENESIS ADDRESS
############################################################

KEYHASH=$(cardano-cli address key-hash \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey")

# 0x60 = enterprise Shelley address for testnet
HEADER="60"

# CBOR byte string:
# 58 = CBOR bytes
# 1d = length (29 bytes)
# then header + 28-byte keyhash
CBOR_ADDRESS="581d${HEADER}${KEYHASH}"

echo "Genesis CBOR Address: $CBOR_ADDRESS"


############################################################
# INSERT INITIAL FUNDS INTO SHELLEY GENESIS
############################################################

jq ".initialFunds = {\"$CBOR_ADDRESS\": {\"lovelace\": 1000000000000}}" \
  "$RUN_CONFIG_DIR/shelley-genesis.json" > "$RUN_CONFIG_DIR/tmp.json"

mv "$RUN_CONFIG_DIR/tmp.json" "$RUN_CONFIG_DIR/shelley-genesis.json"


############################################################
# COMPUTE SHELLEY GENESIS HASH USING PYTHON BLAKE2B-256
############################################################

GENESIS_HASH=$(python3 - <<EOF
import hashlib
data = open("$RUN_CONFIG_DIR/shelley-genesis.json","rb").read()
h = hashlib.blake2b(digest_size=32)
h.update(data)
print(h.hexdigest())
EOF
)

echo "Correct ShelleyGenesisHash = $GENESIS_HASH"

jq ".ShelleyGenesisHash = \"$GENESIS_HASH\"" \
  "$RUN_CONFIG_DIR/config.json" > "$RUN_CONFIG_DIR/tmp.json"

mv "$RUN_CONFIG_DIR/tmp.json" "$RUN_CONFIG_DIR/config.json"


############################################################
# START CARDANO NODE
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
echo "    SANCHONET NODE STARTED"
echo "==============================="
echo "Funding Address (bech32): $ADDRESS"
echo "Genesis CBOR Address:     $CBOR_ADDRESS"
echo "ShelleyGenesisHash:       $GENESIS_HASH"
echo "Logs:                     $BASE_DIR/node.log"
echo ""

tail -f "$BASE_DIR/node.log"
