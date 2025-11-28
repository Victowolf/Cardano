#!/usr/bin/env bash
set -euo pipefail

CARDANO_VERSION="10.1.4"
TARBALL="cardano-node-${CARDANO_VERSION}-linux.tar.gz"
RELEASE_URL="https://github.com/IntersectMBO/cardano-node/releases/download/${CARDANO_VERSION}/${TARBALL}"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$BASE_DIR/config"
DB_DIR="$BASE_DIR/db"
BIN_DIR="/usr/local/bin"
KEYS_DIR="$BASE_DIR/keys"

############################################################
# CLEAN DIRECTORIES
############################################################

rm -rf "$CONFIG_DIR" "$DB_DIR" "$KEYS_DIR"
mkdir -p "$CONFIG_DIR" "$DB_DIR" "$KEYS_DIR"

############################################################
# DOWNLOAD BINARIES
############################################################

if ! command -v cardano-node >/dev/null 2>&1; then
    echo ">>> Downloading Cardano Node ${CARDANO_VERSION}"
    wget -q "$RELEASE_URL" -O "$TARBALL"

    echo ">>> Extracting"
    tar -xf "$TARBALL"

    echo ">>> Installing binaries"
    mv bin/cardano-node "$BIN_DIR/"
    mv bin/cardano-cli "$BIN_DIR/"

    echo ">>> Copying official Sanchonet configs"
    cp -r share/sanchonet/* "$CONFIG_DIR/"

    echo ">>> Cleaning tarball files"
    rm -rf bin lib share "$TARBALL"
fi

############################################################
# GENERATE WALLET
############################################################

echo ">>> Generating wallet keys"

cardano-cli address key-gen \
  --verification-key-file "$KEYS_DIR/payment.vkey" \
  --signing-key-file "$KEYS_DIR/payment.skey"

echo ">>> Building address (testnet magic = 4)"
cardano-cli address build \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey" \
  --testnet-magic 4 \
  > "$KEYS_DIR/payment.addr"

ADDRESS=$(cat "$KEYS_DIR/payment.addr")

echo ">>> Funding address to be added into genesis: $ADDRESS"

############################################################
# UPDATE SHELLEY GENESIS (ADD FUNDS)
############################################################

echo ">>> Adding initial funds to Shelley genesis"
jq ".initialFunds += {\"$ADDRESS\": {\"lovelace\": 1000000000000}}" \
   "$CONFIG_DIR/shelley-genesis.json" > "$CONFIG_DIR/tmp.json"
mv "$CONFIG_DIR/tmp.json" "$CONFIG_DIR/shelley-genesis.json"

############################################################
# COMPUTE GENESIS HASH (robust multi-command probe)
############################################################

compute_shelley_hash() {
  # Try multiple possible cardano-cli invocations in order.
  # Return the first non-empty stdout trimmed.
  # Commands attempted:
  # 1) governance genesis hash --genesis <file>
  # 2) hash file --file <file>
  # 3) hash --file <file>
  # 4) shelley genesis-hash --genesis <file>
  # 5) genesis hash --genesis <file>
  # 6) fallback: sha256sum (NOT guaranteed by cardano-node, but reported if nothing else)
  local GENFILE="$1"
  local out=""

  # helper to attempt a command
  trycmd() {
    local cmd="$1"
    out=$(sh -c "$cmd" 2>/dev/null || true)
    # trim whitespace
    out="$(echo -n "$out" | tr -d ' \t\n\r')"
    if [ -n "$out" ]; then
      echo "$out"
      return 0
    fi
    return 1
  }

  trycmd "cardano-cli governance genesis hash --genesis \"$GENFILE\"" && return 0
  trycmd "cardano-cli hash file --file \"$GENFILE\"" && return 0
  trycmd "cardano-cli hash --file \"$GENFILE\"" && return 0
  trycmd "cardano-cli shelley genesis-hash --genesis \"$GENFILE\"" && return 0
  trycmd "cardano-cli genesis hash --genesis \"$GENFILE\"" && return 0

  # fallback: produce sha256 as last resort (may not be accepted by node)
  if command -v sha256sum >/dev/null 2>&1; then
    out=$(sha256sum "$GENFILE" 2>/dev/null | awk '{print $1}')
    out="$(echo -n "$out" | tr -d ' \t\n\r')"
    if [ -n "$out" ]; then
      echo "$out"
      return 0
    fi
  fi

  return 1
}

echo ">>> Computing updated genesis hash (probing several commands)..."
if ! NEW_HASH="$(compute_shelley_hash "$CONFIG_DIR/shelley-genesis.json")"; then
  echo "ERROR: Could not compute shelley genesis hash with available cardano-cli."
  echo "Please ensure your cardano-cli supports one of these commands:"
  echo "  - cardano-cli governance genesis hash --genesis <file>"
  echo "  - cardano-cli hash file --file <file>"
  echo "  - cardano-cli hash --file <file>"
  echo "  - cardano-cli shelley genesis-hash --genesis <file>"
  echo "  - cardano-cli genesis hash --genesis <file>"
  echo ""
  echo "Debug: cardano-cli --version output:"
  cardano-cli --version || true
  echo ""
  echo "Debug: available 'cardano-cli hash' help:"
  cardano-cli hash --help 2>/dev/null || true
  exit 1
fi

echo ">>> Computed Shelley genesis hash: $NEW_HASH"

############################################################
# UPDATE CONFIG.JSON WITH NEW HASH
############################################################

echo ">>> Updating npcShelleyGenesisFileHash in config.json"
jq ".npcShelleyGenesisFileHash = \"$NEW_HASH\"" \
   "$CONFIG_DIR/config.json" > "$CONFIG_DIR/tmp.json"
mv "$CONFIG_DIR/tmp.json" "$CONFIG_DIR/config.json"

############################################################
# START NODE
############################################################

echo ">>> Starting cardano-node"

cardano-node run \
  --topology "$CONFIG_DIR/topology.json" \
  --database-path "$DB_DIR" \
  --socket-path "$DB_DIR/node.socket" \
  --host-addr 0.0.0.0 \
  --port 3001 \
  --config "$CONFIG_DIR/config.json" \
  > "$BASE_DIR/node.log" 2>&1 &

echo ""
echo "=============================="
echo "  SANCHONET PRIVATE NODE READY"
echo "=============================="
echo "Address: $ADDRESS"
echo "Config: $CONFIG_DIR"
echo ""
echo "Tailing logs..."
tail -f "$BASE_DIR/node.log"
