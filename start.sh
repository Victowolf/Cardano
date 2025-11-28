#!/usr/bin/env bash
set -euo pipefail

# ----------------------------------------------------
# Private Cardano Node Starter (Fixed for Cardano 10.x)
# - Correct Shelley CBOR address generation
# - Valid initialFunds format
# - Pure Python CBOR (no cardano-address dependency)
# ----------------------------------------------------

CARDANO_VERSION="10.1.4"
TARBALL="cardano-node-${CARDANO_VERSION}-linux.tar.gz"
RELEASE_URL="https://github.com/IntersectMBO/cardano-node/releases/download/${CARDANO_VERSION}/${TARBALL}"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
RAW_CONFIG_DIR="$BASE_DIR/config_raw"
RUN_CONFIG_DIR="$BASE_DIR/config"
DB_DIR="$BASE_DIR/db"
KEYS_DIR="$BASE_DIR/keys"
LOG_FILE="$BASE_DIR/node.log"

NETWORK_MAGIC=1337
INITIAL_LOVELACE=1000000000000   # 1 million ADA

rm -rf "$RAW_CONFIG_DIR" "$RUN_CONFIG_DIR" "$DB_DIR" "$KEYS_DIR" "$LOG_FILE"
mkdir -p "$RAW_CONFIG_DIR" "$RUN_CONFIG_DIR" "$DB_DIR" "$KEYS_DIR"

export PATH="/usr/local/bin:$PATH"

echo "==> Ensure cardano-node ${CARDANO_VERSION} present"

if ! (command -v cardano-node >/dev/null 2>&1 && cardano-node version | grep -q "${CARDANO_VERSION}"); then
  echo ">>> Downloading cardano-node ${CARDANO_VERSION}"
  wget -q "$RELEASE_URL" -O "$TARBALL"
  tar -xf "$TARBALL"

  install -m 755 bin/cardano-node /usr/local/bin/cardano-node
  install -m 755 bin/cardano-cli  /usr/local/bin/cardano-cli

  if [ -d "share/sanchonet" ]; then
    cp -r share/sanchonet/* "$RAW_CONFIG_DIR/" || true
  fi

  rm -rf bin lib share "$TARBALL"
fi

echo ">>> cardano-cli version:"
cardano-cli version || true

# Minimal config generation if missing
if [ ! -f "$RAW_CONFIG_DIR/config.json" ]; then
  echo "No config templates found, generating minimal set"

  cat > "$RAW_CONFIG_DIR/config.json" <<JSON
{
  "NodeLoggingFormat": "Json",
  "ShelleyGenesisHash": "",
  "ByronGenesisFile": "byron-genesis.json",
  "AlonzoGenesisFile": "alonzo-genesis.json",
  "ConwayGenesisFile": "conway-genesis.json",
  "Protocol": "Cardano",
  "AcceptableNetworkMagic": $NETWORK_MAGIC
}
JSON

  echo '{}' > "$RAW_CONFIG_DIR/topology.json"
  echo '{}' > "$RAW_CONFIG_DIR/byron-genesis.json"
  echo '{}' > "$RAW_CONFIG_DIR/alonzo-genesis.json"
  echo '{}' > "$RAW_CONFIG_DIR/conway-genesis.json"
fi

cp -r "$RAW_CONFIG_DIR/"* "$RUN_CONFIG_DIR/" || true

# ----------------------------------------------------
# Generate payment keys
# ----------------------------------------------------
echo ">>> Generating payment keys"
cardano-cli address key-gen \
  --verification-key-file "$KEYS_DIR/payment.vkey" \
  --signing-key-file "$KEYS_DIR/payment.skey"

# Bech32 display address
ADDRESS=$(cardano-cli address build \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey" \
  --testnet-magic "$NETWORK_MAGIC")

echo "Funding Address (bech32): $ADDRESS"

# ----------------------------------------------------
# FIXED CBOR ADDRESS (Cardano 10.x)
# ----------------------------------------------------
echo ">>> Building valid Shelley CBOR address"

KEYHASH=$(cardano-cli address key-hash \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey")

CBOR_ADDRESS=$(python3 - <<EOF
import binascii
keyhash = "$KEYHASH"

# Cardano Shelley payment keyhash address format:
#   [ 0: header byte (payment, keyhash, testnet) = 0x66
#     1: CBOR bytestring (0x58 length=0x1c) + keyhash
#   ]
header = 0x66  # payment + keyhash + testnet

cbor = bytearray()
cbor.append(0x82)         # array(2)
cbor.append(header)       # header byte
cbor.append(0x58)         # bytes
cbor.append(0x1c)         # length 28 bytes
cbor += binascii.unhexlify(keyhash)

print(binascii.hexlify(cbor).decode())
EOF
)

echo "Genesis CBOR Address: $CBOR_ADDRESS"

# ----------------------------------------------------
# Shelley Genesis
# ----------------------------------------------------
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
    "extraEntropy": { "tag": "NeutralNonce" },

    "protocolVersion": { "major": 10, "minor": 0 },

    "maxBlockExecutionUnits": { "memory": 10000000, "steps": 5000000000 },
    "maxTxExecutionUnits": { "memory": 5000000, "steps": 2000000000 },

    "prices": { "memory": 0.001, "steps": 0.000000001 },

    "maxValueSize": 5000,
    "collateralPercentage": 150,
    "maxCollateralInputs": 3
  },

  "initialFunds": {
    "$CBOR_ADDRESS": { "lovelace": $INITIAL_LOVELACE }
  },

  "staking": { "pools": {}, "stake": {} },
  "genDelegs": {}
}
JSON

# ----------------------------------------------------
# Patch config.json
# ----------------------------------------------------
echo ">>> Patching config.json"

GENESIS_HASH=$(python3 - <<EOF
import hashlib
d = open("$RUN_CONFIG_DIR/shelley-genesis.json","rb").read()
h = hashlib.blake2b(digest_size=32); h.update(d)
print(h.hexdigest())
EOF
)

python3 - <<EOF
import json
p="$RUN_CONFIG_DIR/config.json"
c=json.load(open(p))
c["ShelleyGenesisHash"]="$GENESIS_HASH"
c["ShelleyGenesisFile"]="shelley-genesis.json"
c["AcceptableNetworkMagic"]=$NETWORK_MAGIC
open(p,"w").write(json.dumps(c, indent=2))
EOF

echo "Correct ShelleyGenesisHash = $GENESIS_HASH"

# ----------------------------------------------------
# START NODE
# ----------------------------------------------------
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
echo " PRIVATE CARDANO NODE STARTED "
echo "==============================="
echo "Funding Address (bech32): $ADDRESS"
echo "Genesis CBOR Address:     $CBOR_ADDRESS"
echo "ShelleyGenesisHash:       $GENESIS_HASH"
echo "Network Magic:            $NETWORK_MAGIC"
echo "Logs:                     $LOG_FILE"
echo ""

tail -f "$LOG_FILE"
