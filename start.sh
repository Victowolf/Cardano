#!/usr/bin/env bash
set -euo pipefail

############################################################
# CONFIG
############################################################

CARDANO_VERSION="10.1.4"
TARBALL="cardano-node-${CARDANO_VERSION}-linux.tar.gz"
RELEASE_URL="https://github.com/IntersectMBO/cardano-node/releases/download/${CARDANO_VERSION}/${TARBALL}"

NETWORK_MAGIC=42
PORT=3001

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="/usr/local/bin"
DB_DIR="$BASE_DIR/db"
CONFIG_DIR="$BASE_DIR/config"
KEYS_DIR="$BASE_DIR/keys"

mkdir -p "$DB_DIR" "$CONFIG_DIR" "$KEYS_DIR"

############################################################
# DOWNLOAD & INSTALL CARDANO BINARIES (NO SUDO)
############################################################

if ! command -v cardano-node >/dev/null 2>&1; then
    echo ">>> Downloading cardano-node ${CARDANO_VERSION}"
    cd "$BASE_DIR"
    wget -q "$RELEASE_URL" -O "$TARBALL"

    echo ">>> Extracting..."
    tar -xf "$TARBALL"

    echo ">>> Installing cardano-node and cardano-cli"
    mv bin/cardano-node "$BIN_DIR/"
    mv bin/cardano-cli "$BIN_DIR/"

    echo ">>> Copying genesis files from tarball"
    cp share/sanchonet/*.json "$CONFIG_DIR/"

    echo ">>> Cleaning extracted folders"
    rm -rf bin lib share
    rm "$TARBALL"
fi

echo "Installed cardano-node: $(cardano-node --version)"
echo "Installed cardano-cli:  $(cardano-cli --version)"

############################################################
# GENESIS (WE STILL KEEP OUR SIMPLE genesis.json)
############################################################

SYSTEM_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo ">>> Writing simple genesis.json"
cat > "$CONFIG_DIR/genesis.json" <<EOF
{
  "systemStart": "$SYSTEM_START",
  "networkMagic": $NETWORK_MAGIC,
  "activeSlotsCoeff": 1.0,
  "securityParam": 10,
  "epochLength": 1000,
  "slotsPerKESPeriod": 1000,
  "maxKESEvolutions": 60,
  "slotLength": 1,
  "updateQuorum": 1,
  "maxLovelaceSupply": 45000000000000000,
  "protocolParams": {
    "minFeeA": 44,
    "minFeeB": 155381,
    "maxTxSize": 16384,
    "maxBlockBodySize": 65536,
    "maxBlockHeaderSize": 1100
  },
  "initialFunds": {},
  "staking": { "pools": {}, "stake": {} }
}
EOF

############################################################
# NODE CONFIG (REQUIRED FOR CARDANO-NODE 10.X)
############################################################
echo ">>> Writing node-config.json"
cat > "$CONFIG_DIR/node-config.json" <<EOF
{
  "Protocol": "Cardano",

  "ByronGenesisFile": "$CONFIG_DIR/byron-genesis.json",
  "ShelleyGenesisFile": "$CONFIG_DIR/shelley-genesis.json",
  "AlonzoGenesisFile": "$CONFIG_DIR/alonzo-genesis.json",
  "ConwayGenesisFile": "$CONFIG_DIR/conway-genesis.json",

  "RequiresNetworkMagic": "RequiresMagic",
  "NetworkMagic": $NETWORK_MAGIC,

  "LastKnownBlockVersion-Major": 7,
  "LastKnownBlockVersion-Minor": 0,

  "EnableP2P": false,
  "minSeverity": "Info"
}
EOF
############################################################
# KEYS + FUND GENESIS
############################################################

echo ">>> Generating wallet keys"

cardano-cli address key-gen \
  --verification-key-file "$KEYS_DIR/payment.vkey" \
  --signing-key-file "$KEYS_DIR/payment.skey"

cardano-cli address build \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey" \
  --testnet-magic $NETWORK_MAGIC \
  > "$KEYS_DIR/payment.addr"

ADDRESS=$(cat "$KEYS_DIR/payment.addr")

echo ">>> Funding simple genesis UTxO for: $ADDRESS"

sed -i "s/\"initialFunds\": {}/\"initialFunds\": {\"$ADDRESS\": {\"lovelace\": 1000000000000}}/" "$CONFIG_DIR/genesis.json"

############################################################
# START NODE
############################################################

echo ">>> Starting cardano-node..."

cardano-node run \
  --topology "$CONFIG_DIR/topology.json" \
  --database-path "$DB_DIR" \
  --socket-path "$DB_DIR/node.socket" \
  --host-addr 0.0.0.0 \
  --port $PORT \
  --config "$CONFIG_DIR/node-config.json" \
  > "$BASE_DIR/node.log" 2>&1 &

echo ""
echo "=============================="
echo "  CARDANO PRIVATE CHAIN READY "
echo "=============================="
echo "Funded Address:"
echo "$ADDRESS"
echo ""
echo "Genesis: $CONFIG_DIR/genesis.json"
echo "Logs: $BASE_DIR/node.log"
echo ""
echo "Tailing logs..."
tail -f "$BASE_DIR/node.log"
