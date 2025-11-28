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
# FORCE NEW BINARY PATH (important!)
############################################################
export PATH="/usr/local/bin:$PATH"

############################################################
# DOWNLOAD CARDANO 10.1.4 (node + cli)
############################################################

if ! cardano-node version 2>/dev/null | grep -q "${CARDANO_VERSION}"; then
    echo ">>> Downloading Cardano Node ${CARDANO_VERSION}"
    wget -q "$RELEASE_URL" -O "$TARBALL"
    tar -xf "$TARBALL"

    # Install binaries and ensure they override system CLI
    install -m 755 bin/cardano-node /usr/local/bin/cardano-node
    install -m 755 bin/cardano-cli /usr/local/bin/cardano-cli

    cp -r share/sanchonet/* "$RAW_CONFIG_DIR/"

    rm -rf bin lib share "$TARBALL"
fi

echo ">>> cardano-cli version:"
cardano-cli version

############################################################
# COPY RAW SANCHONET CONFIG INTO RUN CONFIG DIR
############################################################

cp "$RAW_CONFIG_DIR/"* "$RUN_CONFIG_DIR/"

############################################################
# GENERATE PAYMENT KEYS
############################################################

cardano-cli address key-gen \
  --verification-key-file "$KEYS_DIR/payment.vkey" \
  --signing-key-file "$KEYS_DIR/payment.skey"

# Human-readable bech32 address
ADDRESS=$(cardano-cli address build \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey" \
  --testnet-magic 4)

echo "Funding Address (bech32): $ADDRESS"

############################################################
# GENERATE TRUE CBOR SHELLEY ADDRESS (BINARY)
# This is the FIX that makes genesis accept the address.
############################################################

cardano-cli address build \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey" \
  --testnet-magic 4 \
  --out-file "$KEYS_DIR/payment.addr"

# Convert CBOR binary → hex
CBOR_ADDRESS=$(python3 - <<EOF
import binascii
d=open("$KEYS_DIR/payment.addr","rb").read()
print(binascii.hexlify(d).decode())
EOF
)

echo "Genesis CBOR Address: $CBOR_ADDRESS"

############################################################
# INSERT INITIAL FUNDS INTO GENESIS (VALID ADDRESS NOW!)
############################################################

jq ".initialFunds = {\"$CBOR_ADDRESS\": {\"lovelace\": 1000000000000}}" \
  "$RUN_CONFIG_DIR/shelley-genesis.json" > "$RUN_CONFIG_DIR/tmp.json"

mv "$RUN_CONFIG_DIR/tmp.json" "$RUN_CONFIG_DIR/shelley-genesis.json"

############################################################
# COMPUTE SHELLEY GENESIS HASH
############################################################

GENESIS_HASH=$(python3 - <<EOF
import hashlib
data = open("$RUN_CONFIG_DIR/shelley-genesis.json","rb").read()
h = hashlib.blake2b(digest_size=32); h.update(data)
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
==============================
echo "Funding Address (bech32): $ADDRESS"
echo "Genesis CBOR Address:     $CBOR_ADDRESS"
echo "ShelleyGenesisHash:       $GENESIS_HASH"
echo "Logs:                     $BASE_DIR/node.log"
echo ""

tail -f "$BASE_DIR/node.log"
