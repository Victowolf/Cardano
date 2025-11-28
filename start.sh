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
# COPY NETWORK CONFIG
############################################################

cp "$RAW_CONFIG_DIR/"* "$RUN_CONFIG_DIR/"


############################################################
# GENERATE KEYS + BECH32 ADDRESS
############################################################

cardano-cli address key-gen \
  --verification-key-file "$KEYS_DIR/payment.vkey" \
  --signing-key-file "$KEYS_DIR/payment.skey"

ADDRESS=$(cardano-cli address build \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey" \
  --testnet-magic 4)

echo "Funding Address (bech32): $ADDRESS"


############################################################
# GENERATE CBOR-ENCODED ADDRESS FOR GENESIS
# initialFunds MUST USE CBOR ADDRESS FORMAT
############################################################

# Payment credential hash
KEYHASH=$(cardano-cli address key-hash \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey")

# CBOR = 82 <payment credential> <network tag>
# payment credential is blake2b-28 = 0x581c + keyhash
# network tag (testnet) = 0x01

CBOR_ADDRESS=$(python3 - <<EOF
keyhash="$KEYHASH"
# Construct CBOR: 82, 581c + keyhash, 01 (network id)
cbor = "82" + "581c" + keyhash + "01"
print(cbor)
EOF
)

echo "Genesis CBOR Address: $CBOR_ADDRESS"


############################################################
# INSERT INITIAL FUNDS INTO GENESIS
############################################################

jq ".initialFunds = {\"$CBOR_ADDRESS\": {\"lovelace\": 1000000000000}}" \
  "$RUN_CONFIG_DIR/shelley-genesis.json" > "$RUN_CONFIG_DIR/tmp.json"

mv "$RUN_CONFIG_DIR/tmp.json" "$RUN_CONFIG_DIR/shelley-genesis.json"


############################################################
# COMPUTE GENESIS HASH
############################################################

GENESIS_HASH=$(cardano-cli genesis hash --genesis "$RUN_CONFIG_DIR/shelley-genesis.json")

jq ".ShelleyGenesisHash = \"$GENESIS_HASH\"" \
  "$RUN_CONFIG_DIR/config.json" > "$RUN_CONFIG_DIR/tmp.json"

mv "$RUN_CONFIG_DIR/tmp.json" "$RUN_CONFIG_DIR/config.json"

echo "Correct ShelleyGenesisHash = $GENESIS_HASH"


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
echo "    SANCHONET NODE STARTED"
echo "==============================="
echo "Funding Address (bech32): $ADDRESS"
echo "Genesis CBOR Address:     $CBOR_ADDRESS"
echo "Logs:                     $BASE_DIR/node.log"
echo ""

tail -f "$BASE_DIR/node.log"
