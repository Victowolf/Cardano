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
# COPY ONLY REQUIRED FILES FOR CLEAN CONFIG
############################################################

cp "$RAW_CONFIG_DIR/config.json"         "$RUN_CONFIG_DIR/"
cp "$RAW_CONFIG_DIR/topology.json"       "$RUN_CONFIG_DIR/"
cp "$RAW_CONFIG_DIR/byron-genesis.json"  "$RUN_CONFIG_DIR/"
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
  --testnet-magic 4 \
  > "$KEYS_DIR/payment.addr"

ADDRESS=$(cat "$KEYS_DIR/payment.addr")
echo "Funding address (bech32): $ADDRESS"

############################################################
# Convert bech32 address to raw hex bytes expected by genesis
# Try: 1) cardano-cli address info (if available)
#      2) fallback to embedded python bech32 decoder
############################################################

bech32_to_hex_with_cardano_cli() {
  # cardano-cli address info --address <addr> exists in some versions and prints "address bytes: <hex>"
  if cardano-cli address info --address "$1" >/dev/null 2>&1; then
    HEX=$(cardano-cli address info --address "$1" 2>/dev/null | awk -F': ' '/Address bytes/ {print $2; exit}')
    echo "$HEX"
    return 0
  fi
  return 1
}

bech32_to_hex_with_python() {
  python3 - <<PY
import sys
s = sys.argv[1] if len(sys.argv)>1 else None
if not s:
    print("", end="")
    sys.exit(1)
s = s.strip()
CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
# find separator
pos = s.rfind('1')
if pos == -1:
    print("", end=""); sys.exit(1)
datachars = s[pos+1:]
try:
    data = [CHARSET.index(c) for c in datachars]
except ValueError:
    print("", end=""); sys.exit(1)

def convertbits(data, frombits, tobits, pad=True):
    acc = 0
    bits = 0
    ret = []
    maxv = (1 << tobits) - 1
    for value in data:
        if value < 0 or value >> frombits:
            raise ValueError("Invalid value")
        acc = (acc << frombits) | value
        bits += frombits
        while bits >= tobits:
            bits -= tobits
            ret.append((acc >> bits) & maxv)
    if pad:
        if bits:
            ret.append((acc << (tobits - bits)) & maxv)
    else:
        if bits >= frombits:
            raise ValueError("Illegal zero padding")
        if ((acc << (tobits - bits)) & maxv):
            raise ValueError("Non-zero padding")
    return ret

try:
    decoded = convertbits(data, 5, 8, pad=False)
except Exception:
    print("", end=""); sys.exit(1)
print(bytes(decoded).hex())
PY
}

ADDRESS_HEX=""
# attempt cardano-cli based conversion
if ADDRESS_HEX="$(bech32_to_hex_with_cardano_cli "$ADDRESS")"; then
  echo "Converted address to hex via cardano-cli: $ADDRESS_HEX"
else
  echo "cardano-cli address info not available or didn't return bytes; using embedded python fallback"
  ADDRESS_HEX="$(bech32_to_hex_with_python "$ADDRESS")"
  if [ -z "$ADDRESS_HEX" ]; then
    echo "❌ Could not convert bech32 address to hex. Exiting."
    exit 1
  fi
  echo "Converted address to hex via python fallback: $ADDRESS_HEX"
fi

############################################################
# MODIFY SHELLEY GENESIS (ADD INITIAL FUNDS) using hex key
############################################################

# check existing initialFunds
if jq -e ".initialFunds" "$RUN_CONFIG_DIR/shelley-genesis.json" >/dev/null; then
  # create a temp file with the new initialFunds entry using hex key
  jq ".initialFunds += {\"$ADDRESS_HEX\": {\"lovelace\": 1000000000000}}" \
    "$RUN_CONFIG_DIR/shelley-genesis.json" > "$RUN_CONFIG_DIR/tmp.json"
  mv "$RUN_CONFIG_DIR/tmp.json" "$RUN_CONFIG_DIR/shelley-genesis.json"
else
  # if initialFunds doesn't exist, create it
  jq ". + { initialFunds: {\"$ADDRESS_HEX\": {\"lovelace\": 1000000000000}} }" \
    "$RUN_CONFIG_DIR/shelley-genesis.json" > "$RUN_CONFIG_DIR/tmp.json"
  mv "$RUN_CONFIG_DIR/tmp.json" "$RUN_CONFIG_DIR/shelley-genesis.json"
fi

############################################################
# TRUE BLAKE2B SHELLEY GENESIS HASH FUNCTION
############################################################

compute_hash() {
  local f="$1"

  # Try ALL known hash commands until one succeeds.
  cardano-cli conway genesis hash --genesis "$f"        2>/dev/null && return 0
  cardano-cli genesis hash --genesis "$f"               2>/dev/null && return 0
  cardano-cli shelley genesis hash --genesis "$f"       2>/dev/null && return 0
  cardano-cli genesis hash --shelley-genesis-file "$f"  2>/dev/null && return 0
  cardano-cli governance hash --file "$f"               2>/dev/null && return 0

  return 1
}

echo ">>> Computing correct BLAKE2b Shelley genesis hash..."
if ! NEW_HASH=$(compute_hash "$RUN_CONFIG_DIR/shelley-genesis.json"); then
  echo ""
  echo "❌ ERROR: cardano-cli does not support expected genesis hash commands."
  echo "Dump of available commands:"
  cardano-cli --help
  exit 1
fi

echo "Correct ShelleyGenesisHash = $NEW_HASH"

############################################################
# PATCH THE CORRECT FIELD IN config.json
############################################################

jq ".ShelleyGenesisHash = \"$NEW_HASH\"" \
   "$RUN_CONFIG_DIR/config.json" > "$RUN_CONFIG_DIR/tmp.json"

mv "$RUN_CONFIG_DIR/tmp.json" "$RUN_CONFIG_DIR/config.json"

echo ">>> FINAL PATCHED CONFIG.JSON:"
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
echo "    SANCHONET NODE STARTED     "
echo "==============================="
echo "Address (bech32): $ADDRESS"
echo "Address (hex for genesis initialFunds): $ADDRESS_HEX"
echo "Logs:    $BASE_DIR/node.log"
echo ""

tail -f "$BASE_DIR/node.log"
