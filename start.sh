#!/usr/bin/env bash
set -euo pipefail

############################################################
# SETUP PATHS
############################################################

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
# INSTALL PYTHON CBOR ENCODER
############################################################

pip install cbor2 >/dev/null 2>&1 || \
apt-get update && apt-get install -y python3-pip && pip3 install cbor2

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

# Human-friendly bech32
BECH32_ADDR=$(cardano-cli address build \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey" \
  --testnet-magic 4)

echo "Funding address (bech32): $BECH32_ADDR"

# Keyhash needed for hex address
KEYHASH=$(cardano-cli address key-hash \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey")

echo "Payment keyhash: $KEYHASH"

############################################################
# PYTHON: BUILD SHELLEY HEX ADDRESS FOR GENESIS
############################################################

GENESIS_HEX=$(python3 - <<PY
import hashlib, cbor2, binascii

keyhash = "${KEYHASH}".replace("0x","")
keyhash_bytes = binascii.unhexlify(keyhash)

header = 0x01      # Shelley payment address
network_magic = 4  # Sanchonet

# Shelley testnet address = CBOR encode [header, keyhash_bytes, network_magic]
addr = cbor2.dumps([header, keyhash_bytes, network_magic])

print(binascii.hexlify(addr).decode())
PY
)

echo "Genesis-compatible HEX addr: $GENESIS_HEX"

############################################################
# ADD INITIAL FUNDS USING HEX ADDRESS (REQUIRED)
############################################################

jq ".initialFunds += {\"$GENESIS_HEX\": {\"lovelace\": 1000000000000}}" \
   "$RUN_CONFIG_DIR/shelley-genesis.json" > "$RUN_CONFIG_DIR/tmp.json"

mv "$RUN_CONFIG_DIR/tmp.json" "$RUN_CONFIG_DIR/shelley-genesis.json"

############################################################
# COMPUTE SHELLEY GENESIS HASH
############################################################

echo ">>> Computing correct Shelley Genesis Hash..."
GENESIS_HASH=$(cardano-cli conway genesis hash \
  --genesis "$RUN_CONFIG_DIR/shelley-genesis.json")

echo "Correct ShelleyGenesisHash = $GENESIS_HASH"

############################################################
# PATCH INTO config.json
############################################################

jq ".ShelleyGenesisHash = \"$GENESIS_HASH\"" \
   "$RUN_CONFIG_DIR/config.json" > "$RUN_CONFIG_DIR/tmp.json"

mv "$RUN_CONFIG_DIR/tmp.json" "$RUN_CONFIG_DIR/config.json"

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
echo "   PRIVATE SANCHONET NODE"
echo "          READY"
echo "==============================="
echo "Human Address:    $BECH32_ADDR"
echo "Genesis HEX Addr: $GENESIS_HEX"
echo "Genesis Hash:     $GENESIS_HASH"
echo "Logs:             $BASE_DIR/node.log"
echo ""

tail -f "$BASE_DIR/node.log"
