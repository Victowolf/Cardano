#!/usr/bin/env bash
set -euo pipefail

# -----------------------
# Simple Private Cardano single-node starter
# - Designed for local / k8s dev
# - Injects initialFunds (1,000,000 ADA as lovelace 1e12)
# - Uses Python to produce CBOR Shelley address (no --with-cbor cli)
# - Uses a unique network magic so this is a private chain
# -----------------------

CARDANO_VERSION="10.1.4"
TARBALL="cardano-node-${CARDANO_VERSION}-linux.tar.gz"
RELEASE_URL="https://github.com/IntersectMBO/cardano-node/releases/download/${CARDANO_VERSION}/${TARBALL}"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RAW_CONFIG_DIR="$BASE_DIR/config_raw"
RUN_CONFIG_DIR="$BASE_DIR/config"
DB_DIR="$BASE_DIR/db"
KEYS_DIR="$BASE_DIR/keys"
LOG_FILE="$BASE_DIR/node.log"

# private network magic (choose a number unlikely to collide)
NETWORK_MAGIC=1337

# initial funds (lovelace)
INITIAL_LOVELACE=1000000000000    # 1,000,000 ADA = 1e12 lovelace

# cleanup old
rm -rf "$RAW_CONFIG_DIR" "$RUN_CONFIG_DIR" "$DB_DIR" "$KEYS_DIR" "$LOG_FILE"
mkdir -p "$RAW_CONFIG_DIR" "$RUN_CONFIG_DIR" "$DB_DIR" "$KEYS_DIR"

# ensure /usr/local/bin is used first
export PATH="/usr/local/bin:$PATH"

echo "==> Ensure cardano-node ${CARDANO_VERSION} & cardano-cli are available (will install if missing)"

# Download and extract the release tarball if we don't already have a node binary of the target version.
if ! (command -v cardano-node >/dev/null 2>&1 && cardano-node version 2>/dev/null | grep -q "${CARDANO_VERSION}") ; then
  echo ">>> Downloading cardano-node ${CARDANO_VERSION}"
  wget -q "$RELEASE_URL" -O "$TARBALL"
  tar -xf "$TARBALL"

  # install binaries (overwrite if present)
  install -m 755 bin/cardano-node /usr/local/bin/cardano-node
  install -m 755 bin/cardano-cli  /usr/local/bin/cardano-cli

  # copy sample configs if provided (the tarball often contains sample config sets)
  if [ -d "share/sanchonet" ]; then
    cp -r share/sanchonet/* "$RAW_CONFIG_DIR/" || true
  fi

  rm -rf bin lib share "$TARBALL"
fi

echo ">>> cardano-cli version:"
cardano-cli version || true

# If no raw configs were found, create a minimal config set so the node can run.
if [ ! -f "$RAW_CONFIG_DIR/config.json" ]; then
  echo "No sample configs found in tarball; writing minimal config templates..."

  mkdir -p "$RAW_CONFIG_DIR"
  # Minimal config.json (sane defaults) - this is minimal and intended only for dev/private chains
  cat > "$RAW_CONFIG_DIR/config.json" <<JSON
{
  "NodeLoggingFormat": "Json",
  "ShelleyGenesisHash": "",
  "ByronGenesisFile": "byron-genesis.json",
  "AlonzoGenesisFile": "alonzo-genesis.json",
  "ConwayGenesisFile": "conway-genesis.json",
  "Protocol": "Cardano",
  "SocksProxy": null
}
JSON

  # Minimal topology.json (no peers; single-node)
  cat > "$RAW_CONFIG_DIR/topology.json" <<JSON
{
  "Producers": []
}
JSON

  # Minimal byron/alonzo/conway genesis placeholders
  cp /dev/null "$RAW_CONFIG_DIR/byron-genesis.json" || true
  cp /dev/null "$RAW_CONFIG_DIR/alonzo-genesis.json" || true
  cp /dev/null "$RAW_CONFIG_DIR/conway-genesis.json" || true
fi

# copy into run dir
cp -r "$RAW_CONFIG_DIR/"* "$RUN_CONFIG_DIR/" || true

# ---------------------------
# Generate payment keys
# ---------------------------
echo ">>> Generating payment key pair"
cardano-cli address key-gen \
  --verification-key-file "$KEYS_DIR/payment.vkey" \
  --signing-key-file "$KEYS_DIR/payment.skey"

# build bech32 address (human readable)
ADDRESS=$(cardano-cli address build \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey" \
  --testnet-magic "$NETWORK_MAGIC")

echo "Funding Address (bech32): $ADDRESS"

# ---------------------------
# Build CBOR Shelley address (independent of CLI CBOR support)
# ---------------------------
echo ">>> Building CBOR Shelley address from payment key hash"

KEYHASH=$(cardano-cli address key-hash \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey")

CBOR_ADDRESS=$(python3 - <<EOF
import binascii
keyhash = "$KEYHASH"
# Use network_id = 0 for our private dev addresses (header = 0x60)
network_id = 0x00
header = 0x60 | network_id
cbor = bytearray()
cbor.append(0x82)       # array(2)
cbor.append(header)     # address header
cbor.append(0x58)       # bytes (one-byte length)
cbor.append(0x1c)       # 28 bytes length
cbor += binascii.unhexlify(keyhash)
print(binascii.hexlify(cbor).decode())
EOF
)

echo "Genesis CBOR Address: $CBOR_ADDRESS"

############################################################
# WRITE A MODERN SHELLEY GENESIS (Cardano 10.x Compatible)
############################################################

SYSTEM_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

cat > "$RUN_CONFIG_DIR/shelley-genesis.json" <<JSON
{
  "activeSlotsCoeff": 0.1,
  "updateQuorum": 5,
  "networkId": "Testnet",
  "networkMagic": $NETWORK_MAGIC,
  "epochLength": 432000,
  "systemStart": "$SYSTEM_START",
  "slotsPerKESPeriod": 129600,
  "slotLength": 1,
  "maxKESEvolutions": 62,
  "securityParam": 2160,

  "maxLovelaceSupply": 45000000000000000,

  "protocolParams": {
    "minFeeA": 44,
    "minFeeB": 155381,
    "maxBlockBodySize": 65536,
    "maxTxSize": 16384,
    "maxBlockHeaderSize": 1100,

    "keyDeposit": 2000000,
    "poolDeposit": 500000000,

    "eMax": 18,
    "nOpt": 150,

    "a0": 0.3,
    "rho": 0.003,
    "tau": 0.20,

    "poolPledgeInfluence": 0.3,
    "monetaryExpansion": 0.003,
    "treasuryCut": 0.20,

    "decentralisationParam": 1.0,
    "extraEntropy": { "neutral": true },

    "protocolVersion": {
      "major": 10,
      "minor": 0
    },

    "maxBlockExecutionUnits": {
      "memory": 10000000,
      "steps": 5000000000
    },
    "maxTxExecutionUnits": {
      "memory": 5000000,
      "steps": 2000000000
    },

    "prices": {
      "memory": 0.001,
      "steps": 0.000000001
    },

    "maxValueSize": 5000,

    "collateralPercentage": 150,
    "maxCollateralInputs": 3
  },

  "initialFunds": {
    "$CBOR_ADDRESS": { "lovelace": $INITIAL_LOVELACE }
  },

  "staking": {
    "pools": {},
    "stake": {}
  },

  "genDelegs": {}
}
JSON

# ---------------------------
# Patch config.json to reference shelley-genesis and set network magic & other sane defaults
# ---------------------------
echo ">>> Patching config.json for private network"

# Create a minimal config.json if missing keys
if [ ! -f "$RUN_CONFIG_DIR/config.json" ]; then
  cat > "$RUN_CONFIG_DIR/config.json" <<JSON
{
  "protocol": "Cardano",
  "ByronGenesisFile": "byron-genesis.json",
  "AlonzoGenesisFile": "alonzo-genesis.json",
  "ConwayGenesisFile": "conway-genesis.json",
  "ShelleyGenesisFile": "shelley-genesis.json",
  "ShelleyGenesisHash": "",
  "AcceptableNetworkMagic": $NETWORK_MAGIC
}
JSON
fi

# Compute ShelleyGenesisHash (blake2b-256) — CORRECT: hash of the file content
GENESIS_HASH=$(python3 - <<EOF
import hashlib
d = open("$RUN_CONFIG_DIR/shelley-genesis.json","rb").read()
h = hashlib.blake2b(digest_size=32)
h.update(d)
print(h.hexdigest())
EOF
)

# Update config.json's ShelleyGenesisHash (use jq if available)
if command -v jq >/dev/null 2>&1; then
  jq ".ShelleyGenesisHash = \"$GENESIS_HASH\" | .ShelleyGenesisFile = \"shelley-genesis.json\" | .AcceptableNetworkMagic = $NETWORK_MAGIC" \
    "$RUN_CONFIG_DIR/config.json" > "$RUN_CONFIG_DIR/tmp.json"
  mv "$RUN_CONFIG_DIR/tmp.json" "$RUN_CONFIG_DIR/config.json"
else
  python3 - <<PY
import json
p="$RUN_CONFIG_DIR/config.json"
c=json.load(open(p))
c["ShelleyGenesisHash"]="$GENESIS_HASH"
c["ShelleyGenesisFile"]="shelley-genesis.json"
c["AcceptableNetworkMagic"]=$NETWORK_MAGIC
open(p,"w").write(json.dumps(c, indent=2))
PY
fi

echo "Correct ShelleyGenesisHash = $GENESIS_HASH"

# ---------------------------
# Start the node
# ---------------------------
echo ">>> Starting cardano-node..."

cardano-node run \
  --topology "$RUN_CONFIG_DIR/topology.json" \
  --database-path "$DB_DIR" \
  --socket-path "$DB_DIR/node.socket" \
  --host-addr 0.0.0.0 \
  --port 3001 \
  --config "$RUN_CONFIG_DIR/config.json" \
  > "$LOG_FILE" 2>&1 &

sleep 2

echo ""
echo "==============================="
echo "    PRIVATE CARDANO NODE STARTED"
echo "==============================="
echo "Funding Address (bech32): $ADDRESS"
echo "Genesis CBOR Address:     $CBOR_ADDRESS"
echo "ShelleyGenesisHash:       $GENESIS_HASH"
echo "Network Magic:            $NETWORK_MAGIC"
echo "Logs:                     $LOG_FILE"
echo ""

tail -f "$LOG_FILE"
