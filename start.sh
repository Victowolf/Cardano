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
TMP_DIR="$BASE_DIR/tmp"

rm -rf "$RAW_CONFIG_DIR" "$RUN_CONFIG_DIR" "$DB_DIR" "$KEYS_DIR" "$TMP_DIR"
mkdir -p "$RAW_CONFIG_DIR" "$RUN_CONFIG_DIR" "$DB_DIR" "$KEYS_DIR" "$TMP_DIR"

############################################################
# DOWNLOAD BINARIES (if not present)
############################################################
if ! command -v cardano-node >/dev/null 2>&1; then
  echo ">>> Downloading Cardano Node ${CARDANO_VERSION}"
  wget -q "$RELEASE_URL" -O "$TARBALL"
  echo ">>> Extracting"
  tar -xf "$TARBALL"

  echo ">>> Installing binaries to /usr/local/bin"
  mv bin/cardano-node /usr/local/bin/
  mv bin/cardano-cli  /usr/local/bin/

  echo ">>> Copying Sanchonet configs to raw folder"
  cp -r share/sanchonet/* "$RAW_CONFIG_DIR/"

  echo ">>> Cleanup tarball and extracted helpers"
  rm -rf bin lib share "$TARBALL"
fi

############################################################
# COPY ONLY REQUIRED FILES FOR CLEAN CONFIG
############################################################
cp "$RAW_CONFIG_DIR/config.json"          "$RUN_CONFIG_DIR/" || true
cp "$RAW_CONFIG_DIR/topology.json"        "$RUN_CONFIG_DIR/" || true
cp "$RAW_CONFIG_DIR/byron-genesis.json"   "$RUN_CONFIG_DIR/" || true
cp "$RAW_CONFIG_DIR/shelley-genesis.json" "$RUN_CONFIG_DIR/" || true
cp "$RAW_CONFIG_DIR/alonzo-genesis.json"  "$RUN_CONFIG_DIR/" || true
cp "$RAW_CONFIG_DIR/conway-genesis.json"  "$RUN_CONFIG_DIR/" || true

echo ">>> Clean config files prepared in $RUN_CONFIG_DIR"

############################################################
# GENERATE KEYS AND ADDRESSES
############################################################
echo ">>> Generating wallet keys"
cardano-cli address key-gen \
  --verification-key-file "$KEYS_DIR/payment.vkey" \
  --signing-key-file      "$KEYS_DIR/payment.skey"

# human readable bech32 (for your use / display)
cardano-cli address build \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey" \
  --testnet-magic 4 \
  --out-file "$KEYS_DIR/payment.addr.bech32"

BECH32_ADDR="$(cat "$KEYS_DIR/payment.addr.bech32")"
echo "Bech32 address (human): $BECH32_ADDR"

# genesis-compatible hex address (CBOR/hex) — ensure CLI supports --output-format hex or writing hex
HEX_OUT="$KEYS_DIR/payment.addr.hex"
# many cardano-cli versions accept --output-format hex with --out-file
cardano-cli address build \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey" \
  --testnet-magic 4 \
  --output-format hex \
  --out-file "$HEX_OUT"

if [ ! -s "$HEX_OUT" ]; then
  echo "ERROR: could not produce hex address to $HEX_OUT"
  echo "Attempt: try 'cardano-cli address build --output-format hex' manually in container"
  exit 1
fi

RAW_ADDR="$(cat "$HEX_OUT" | tr -d '\n\r')"
echo "Hex (genesis) address: $RAW_ADDR"

############################################################
# INSERT RAW_ADDR INTO SHELLEY GENESIS (hex required)
############################################################
echo ">>> Inserting initial funds into shelley-genesis.json (hex address)"
# Use jq with arg to avoid quoting issues
jq --arg addr "$RAW_ADDR" '.initialFunds += {($addr): {"lovelace": 1000000000000}}' \
   "$RUN_CONFIG_DIR/shelley-genesis.json" > "$TMP_DIR/shelley-genesis.json.tmp"
mv "$TMP_DIR/shelley-genesis.json.tmp" "$RUN_CONFIG_DIR/shelley-genesis.json"

echo ">>> shelley-genesis.json updated"

############################################################
# Compute correct BLAKE2b Shelley genesis hash (try CLI variants)
############################################################
compute_hash() {
  local f="$1"
  local out

  # Try known cardano-cli variants — first successful non-empty output wins
  out="$(cardano-cli conway genesis hash --genesis "$f" 2>/dev/null || true)"
  out="$(echo -n "$out" | tr -d ' \t\n\r')"
  if [ -n "$out" ]; then echo "$out"; return 0; fi

  out="$(cardano-cli genesis hash --genesis "$f" 2>/dev/null || true)"
  out="$(echo -n "$out" | tr -d ' \t\n\r')"
  if [ -n "$out" ]; then echo "$out"; return 0; fi

  out="$(cardano-cli shelley genesis hash --genesis "$f" 2>/dev/null || true)"
  out="$(echo -n "$out" | tr -d ' \t\n\r')"
  if [ -n "$out" ]; then echo "$out"; return 0; fi

  out="$(cardano-cli genesis hash --shelley-genesis-file "$f" 2>/dev/null || true)"
  out="$(echo -n "$out" | tr -d ' \t\n\r')"
  if [ -n "$out" ]; then echo "$out"; return 0; fi

  out="$(cardano-cli governance hash --file "$f" 2>/dev/null || true)"
  out="$(echo -n "$out" | tr -d ' \t\n\r')"
  if [ -n "$out" ]; then echo "$out"; return 0; fi

  # Some cardano-cli versions only have 'hash file --file'. Try that:
  out="$(cardano-cli hash file --file "$f" 2>/dev/null || true)"
  out="$(echo -n "$out" | tr -d ' \t\n\r')"
  if [ -n "$out" ]; then echo "$out"; return 0; fi

  # fallback: try cardano-cli hash --help to guide debug (won't return hash)
  return 1
}

echo ">>> Computing BLAKE2b genesis hash for shelley-genesis.json..."
if ! NEW_HASH="$(compute_hash "$RUN_CONFIG_DIR/shelley-genesis.json")"; then
  echo "ERROR: could not compute BLAKE2b genesis hash with available cardano-cli"
  echo "cardano-cli --version:"
  cardano-cli --version || true
  echo "Available 'hash' help:"
  cardano-cli hash --help 2>/dev/null || true
  exit 1
fi

echo ">>> Computed ShelleyGenesisHash: $NEW_HASH"

############################################################
# PATCH THE CORRECT FIELD IN config.json
############################################################
echo ">>> Patching ShelleyGenesisHash in config.json"
jq --arg h "$NEW_HASH" '.ShelleyGenesisHash = $h' \
  "$RUN_CONFIG_DIR/config.json" > "$TMP_DIR/config.json.tmp"
mv "$TMP_DIR/config.json.tmp" "$RUN_CONFIG_DIR/config.json"

echo ">>> Final config.json:"
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
echo "Bech32 Address: $BECH32_ADDR"
echo "Hex   Address: $RAW_ADDR"
echo "Logs: $BASE_DIR/node.log"
echo ""

tail -f "$BASE_DIR/node.log"
