#!/usr/bin/env bash
set -euo pipefail

############################################################
# DIRECTORIES & VARIABLES
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

LOG="$BASE_DIR/start.log"
exec 3>&1 1>>"$LOG" 2>&1

echo "=== start.sh invoked at $(date -u +"%Y-%m-%dT%H:%M:%SZ") ===" >&3

############################################################
# BASIC TOOLING (defensive)
############################################################

# minimal installer function that tries apt then exits gracefully if not available
install_pkg() {
  pkg="$1"
  if command -v "$pkg" >/dev/null 2>&1; then
    echo " - $pkg present" >&3
    return 0
  fi

  if command -v apt-get >/dev/null 2>&1; then
    echo "apt-get present, installing $pkg" >&3
    apt-get update -y || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$pkg"
  else
    echo "WARNING: apt-get not present; required package $pkg may be missing" >&3
  fi
}

# ensure essential tools are available (wget, jq, git, python3)
install_pkg wget
install_pkg git
install_pkg jq
install_pkg python3
install_pkg ca-certificates
install_pkg curl

# ensure pip (use python -m pip to be robust)
if ! python3 -m pip --version >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y || true
    apt-get install -y --no-install-recommends python3-pip
  else
    echo "ERROR: pip not available and apt-get not present. Please ensure python3-pip is installed." >&3
    exit 1
  fi
fi

# install python cbor2 and ensure jq exists
python3 -m pip install --quiet --upgrade pip setuptools wheel || true
python3 -m pip install --quiet cbor2

# ensure jq truly exists
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required but not installed." >&3
  exit 1
fi

############################################################
# DOWNLOAD CARDANO BINARIES + SANCHONET CONFIG
############################################################

if ! command -v cardano-node >/dev/null 2>&1; then
    echo ">>> Downloading Cardano Node ${CARDANO_VERSION}" >&3

    # download with retries
    retry=0
    until [ $retry -ge 3 ]
    do
      wget -q "$RELEASE_URL" -O "$TARBALL" && break
      echo "wget failed, retrying..." >&3
      retry=$((retry+1))
      sleep 2
    done

    if [ ! -f "$TARBALL" ]; then
      echo "ERROR: failed to download ${TARBALL}" >&3
      exit 1
    fi

    tar -xf "$TARBALL"

    # move binaries (if present)
    if [ -f bin/cardano-node ]; then
      mv bin/cardano-node /usr/local/bin/
    fi
    if [ -f bin/cardano-cli ]; then
      mv bin/cardano-cli  /usr/local/bin/
    fi

    # copy sanchonet config if present in release
    if [ -d share/sanchonet ]; then
      cp -r share/sanchonet/* "$RAW_CONFIG_DIR/" || true
    else
      echo "WARNING: share/sanchonet not found in archive; ensure your release contains sanchonet templates." >&3
    fi

    rm -rf bin lib share "$TARBALL"
fi

if ! command -v cardano-cli >/dev/null 2>&1; then
  echo "ERROR: cardano-cli not available after install." >&3
  exit 1
fi

echo "cardano-cli version:" >&3
cardano-cli version >&3 || true

############################################################
# COPY SANCHONET CONFIGS (if available)
############################################################

for f in config.json topology.json byron-genesis.json shelley-genesis.json alonzo-genesis.json conway-genesis.json; do
  if [ -f "$RAW_CONFIG_DIR/$f" ]; then
    cp "$RAW_CONFIG_DIR/$f" "$RUN_CONFIG_DIR/"
  else
    echo "WARNING: $f not present in $RAW_CONFIG_DIR; continuing (some configs may be missing)" >&3
  fi
done

############################################################
# GENERATE PAYMENT KEYPAIR
############################################################

cardano-cli address key-gen \
  --verification-key-file "$KEYS_DIR/payment.vkey" \
  --signing-key-file "$KEYS_DIR/payment.skey"

# bech32 human address for display
BECH32_ADDR=$(cardano-cli address build \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey" \
  --testnet-magic 4)

echo "Human Address: $BECH32_ADDR" >&3

############################################################
# BUILD GENESIS-VALID ENTERPRISE HEX ADDRESS (correct pubkey extraction)
############################################################

GENESIS_HEX=$(python3 - <<'PY'
import hashlib, binascii, cbor2, json, sys

vkey_path = sys.argv[1]
with open(vkey_path) as f:
    vkey_json = json.load(f)

# vkey_json["cborHex"] is CBOR bytestring: 58 20 <32-byte pubkey>
cbor_hex = vkey_json.get("cborHex")
if not cbor_hex:
    raise SystemExit("vkey cborHex not found")

vkey_cbor = binascii.unhexlify(cbor_hex)
# skip CBOR bytestring header (0x58 0x20) if present
if len(vkey_cbor) >= 34 and vkey_cbor[0] == 0x58:
    # second byte is length; usually 0x20 for 32 bytes
    pubkey = vkey_cbor[2:]
else:
    # fallback: assume the full payload is the pubkey
    pubkey = vkey_cbor

if len(pubkey) != 32:
    raise SystemExit("Extracted pubkey length != 32 bytes (got {}).".format(len(pubkey)))

# Blake2b-224 hash
keyhash = hashlib.blake2b(pubkey, digest_size=28).digest()

# enterprise header (payment-only, testnet network id = 0)
header = bytes([0x60])
addr_raw = header + keyhash
addr_cbor = cbor2.dumps(addr_raw)

print(binascii.hexlify(addr_cbor).decode())
PY
"$KEYS_DIR/payment.vkey"
)

echo "Genesis HEX Address: $GENESIS_HEX" >&3

############################################################
# INSERT INITIAL FUNDS INTO GENESIS
############################################################

if [ -f "$RUN_CONFIG_DIR/shelley-genesis.json" ]; then
  jq ".initialFunds += {\"$GENESIS_HEX\": {\"lovelace\": 1000000000000}}" \
    "$RUN_CONFIG_DIR/shelley-genesis.json" > "$RUN_CONFIG_DIR/tmp.json"
  mv "$RUN_CONFIG_DIR/tmp.json" "$RUN_CONFIG_DIR/shelley-genesis.json"
else
  echo "ERROR: $RUN_CONFIG_DIR/shelley-genesis.json not found; cannot add initialFunds" >&3
  exit 1
fi

############################################################
# COMPUTE GENESIS HASH (robust)
############################################################

compute_hash() {
  local f="$1"
  cardano-cli conway genesis hash --genesis "$f" 2>/dev/null && return 0
  cardano-cli genesis hash --genesis "$f" 2>/dev/null && return 0
  cardano-cli shelley genesis hash --genesis "$f" 2>/dev/null && return 0
  cardano-cli genesis hash --shelley-genesis-file "$f" 2>/dev/null && return 0
  cardano-cli governance hash --file "$f" 2>/dev/null && return 0
  return 1
}

echo ">>> Computing correct BLAKE2b Shelley genesis hash..." >&3
if ! NEW_HASH=$(compute_hash "$RUN_CONFIG_DIR/shelley-genesis.json"); then
  echo "ERROR: cardano-cli does not support expected genesis hash commands." >&3
  cardano-cli --help >&3 || true
  exit 1
fi

echo "Correct ShelleyGenesisHash = $NEW_HASH" >&3

############################################################
# PATCH config.json
############################################################

if [ -f "$RUN_CONFIG_DIR/config.json" ]; then
  jq ".ShelleyGenesisHash = \"$NEW_HASH\"" "$RUN_CONFIG_DIR/config.json" > "$RUN_CONFIG_DIR/tmp.json"
  mv "$RUN_CONFIG_DIR/tmp.json" "$RUN_CONFIG_DIR/config.json"
  echo "Patched config.json:" >&3
  cat "$RUN_CONFIG_DIR/config.json" >&3
else
  echo "ERROR: $RUN_CONFIG_DIR/config.json not found; cannot patch ShelleyGenesisHash" >&3
  exit 1
fi

############################################################
# START NODE
############################################################

echo ">>> Starting cardano-node..." >&3

cardano-node run \
  --topology "$RUN_CONFIG_DIR/topology.json" \
  --database-path "$DB_DIR" \
  --socket-path "$DB_DIR/node.socket" \
  --host-addr 0.0.0.0 \
  --port 3001 \
  --config "$RUN_CONFIG_DIR/config.json" \
  > "$BASE_DIR/node.log" 2>&1 &

sleep 2

echo "" >&3
echo "===============================" >&3
echo " PRIVATE SANCHONET NODE READY" >&3
echo "===============================" >&3
echo "Human Address:    $BECH32_ADDR" >&3
echo "Genesis HEX Addr: $GENESIS_HEX" >&3
echo "Genesis Hash:     $NEW_HASH" >&3
echo "Logs:             $BASE_DIR/node.log" >&3
echo "" >&3

# also print last 200 lines of node.log to stdout (useful in CI)
if [ -f "$BASE_DIR/node.log" ]; then
  tail -n 200 "$BASE_DIR/node.log" >&3 || true
fi

# keep container alive by tailing the node log
exec tail -f "$BASE_DIR/node.log"
