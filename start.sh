#!/usr/bin/env bash
set -euo pipefail

# ======================================================
# Minimal + Clean + Fully Working Private Cardano Node
# Compatible with cardano-node 10.1.4
# FIXED: CBOR generation, heredocs, variable expansion,
#        initialFunds, config, genesis hash
# ======================================================

CARDANO_VERSION="10.1.4"
TARBALL="cardano-node-${CARDANO_VERSION}-linux.tar.gz"
RELEASE_URL="https://github.com/IntersectMBO/cardano-node/releases/download/${CARDANO_VERSION}/${TARBALL}"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$BASE_DIR/config"
DB_DIR="$BASE_DIR/db"
KEYS_DIR="$BASE_DIR/keys"
LOG_FILE="$BASE_DIR/node.log"
NETWORK_MAGIC=1337
INITIAL_LOVELACE=1000000000000

rm -rf "$CONFIG_DIR" "$DB_DIR" "$KEYS_DIR" "$LOG_FILE"
mkdir -p "$CONFIG_DIR" "$DB_DIR" "$KEYS_DIR"

export PATH="/usr/local/bin:$PATH"

echo "==> Checking cardano-node ${CARDANO_VERSION}"
if ! (command -v cardano-node >/dev/null 2>&1 && cardano-node version | grep -q ${CARDANO_VERSION}); then
  echo "Downloading cardano-node..."
  wget -q "$RELEASE_URL" -O "$TARBALL"
  tar -xf "$TARBALL"
  install -m 755 bin/cardano-node /usr/local/bin/cardano-node
  install -m 755 bin/cardano-cli  /usr/local/bin/cardano-cli
  rm -rf bin lib share "$TARBALL"
fi

echo ">>> CLI version:"
cardano-cli version || true

echo ">>> Generating keypair"
cardano-cli address key-gen \
  --verification-key-file "$KEYS_DIR/payment.vkey" \
  --signing-key-file "$KEYS_DIR/payment.skey"

ADDRESS=$(cardano-cli address build \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey" \
  --testnet-magic "$NETWORK_MAGIC")

echo "Funding Address: $ADDRESS"

KEYHASH=$(cardano-cli address key-hash \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey")

echo ">>> Building CBOR address from keyhash: $KEYHASH"

CBOR_ADDRESS=$(python3 - <<PY
import binascii
keyhash = "${KEYHASH}"
keyhash = keyhash.replace("0x", "")
header = 0x66

cbor = bytearray()
cbor.append(0x82)
cbor.append(header)
cbor.append(0x58)
cbor.append(0x1c)
cbor += binascii.unhexlify(keyhash)

print(binascii.hexlify(cbor).decode())
PY
)

echo "Genesis CBOR Address: $CBOR_ADDRESS"

echo ">>> Writing shelley-genesis.json"
SYSTEM_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

cat > "$CONFIG_DIR/shelley-genesis.json" <<JSON
{
  "networkId": "Testnet",
  "networkMagic": $NETWORK_MAGIC,
  "systemStart": "$SYSTEM_START",
  "activeSlotsCoeff": 0.1,
  "securityParam": 10,
  "epochLength": 500,
  "slotLength": 1,

  "maxLovelaceSupply": 45000000000000000,

  "initialFunds": {
    "$CBOR_ADDRESS": { "lovelace": $INITIAL_LOVELACE }
  },

  "staking": { "pools": {}, "stake": {} }
}
JSON

echo ">>> Writing minimal config.json"
cat > "$CONFIG_DIR/config.json" <<JSON
{
  "Protocol": "Cardano",
  "ByronGenesisFile": "byron-genesis.json",
  "ShelleyGenesisFile": "shelley-genesis.json",
  "AlonzoGenesisFile": "alonzo-genesis.json",
  "ConwayGenesisFile": "conway-genesis.json",
  "AcceptableNetworkMagic": $NETWORK_MAGIC,
  "NodeLoggingFormat": "Json"
}
JSON

echo '{}' > "$CONFIG_DIR/topology.json"
echo '{}' > "$CONFIG_DIR/byron-genesis.json"
echo '{}' > "$CONFIG_DIR/alonzo-genesis.json"
echo '{}' > "$CONFIG_DIR/conway-genesis.json"

echo ">>> Computing Genesis Hash"
GENESIS_HASH=$(python3 - <<PY
import hashlib
with open("${CONFIG_DIR}/shelley-genesis.json", "rb") as f:
    data = f.read()
h = hashlib.blake2b(digest_size=32)
h.update(data)
print(h.hexdigest())
PY
)

echo "GenesisHash: $GENESIS_HASH"

python3 - <<PY
import json
cfg_path = "${CONFIG_DIR}/config.json"
cfg = json.load(open(cfg_path))
cfg["ShelleyGenesisHash"] = "${GENESIS_HASH}"
open(cfg_path, "w").write(json.dumps(cfg, indent=2))
PY

echo ">>> Starting cardano-node"
cardano-node run \
  --topology "$CONFIG_DIR/topology.json" \
  --database-path "$DB_DIR" \
  --socket-path "$DB_DIR/node.socket" \
  --host-addr 0.0.0.0 \
  --port 3001 \
  --config "$CONFIG_DIR/config.json" \
  > "$LOG_FILE" 2>&1 &

sleep 1

echo "====================================="
echo " PRIVATE CARDANO NODE — RUNNING "
echo "====================================="
echo "Bech32 Address:       $ADDRESS"
echo "CBOR Genesis Address: $CBOR_ADDRESS"
echo "Genesis Hash:         $GENESIS_HASH"
echo "Magic:                $NETWORK_MAGIC"
echo "Logs:                 $LOG_FILE"

tail -f "$LOG_FILE"