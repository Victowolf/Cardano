#!/usr/bin/env bash
set -euo pipefail

##########################################################################
# CONFIGURATION
##########################################################################

CARDANO_VERSION="10.1.4"
RELEASE_URL="https://github.com/IntersectMBO/cardano-node/releases/download/${CARDANO_VERSION}/cardano-node-${CARDANO_VERSION}-linux.tar.gz"
NETWORK_MAGIC=42
PORT=3001

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
DB_DIR="$BASE_DIR/db"
CONFIG_DIR="$BASE_DIR/config"
KEYS_DIR="$BASE_DIR/keys"

mkdir -p "$DB_DIR" "$CONFIG_DIR" "$KEYS_DIR"

##########################################################################
# DOWNLOAD CARDANO BINARIES
##########################################################################

echo ">>> Checking for cardano-node & cardano-cli"

if ! command -v cardano-node >/dev/null 2>&1; then
    echo "Downloading cardano-node ${CARDANO_VERSION}..."
    wget -q "$RELEASE_URL" -O cardano.tar.gz
    tar -xvf cardano.tar.gz
    sudo mv cardano-node /usr/local/bin/
    sudo mv cardano-cli /usr/local/bin/
    rm cardano.tar.gz
fi

echo ">>> cardano-node installed: $(cardano-node --version)"
echo ">>> cardano-cli installed:  $(cardano-cli --version)"

##########################################################################
# GENESIS + PROTOCOL PARAMETERS
##########################################################################

echo ">>> Creating genesis.json and protocol parameters"

SYSTEM_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

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
    "maxBlockHeaderSize": 1100,
    "keyDeposit": 400000,
    "poolDeposit": 500000000,
    "eMax": 18,
    "nOpt": 50,
    "a0": 0.3,
    "rho": 0.003,
    "tau": 0.2,
    "decayConstant": -3,
    "minPoolCost": 0,
    "coinsPerUTxOByte": 4310
  },
  "initialFunds": {},
  "staking": { "pools": {}, "stake": {} }
}
EOF

##########################################################################
# NODE CONFIG + TOPOLOGY
##########################################################################

echo ">>> Creating node-config.json"

cat > "$CONFIG_DIR/node-config.json" <<EOF
{
  "Protocol": "Babbage",
  "TraceBlockFetchDecisions": false,
  "TraceChainDb": false,
  "TraceMempool": false,
  "TraceForge": true,
  "EnableLogMetrics": false,
  "EnableTracing": true,
  "minSeverity": "Info",
  "NetworkMagic": $NETWORK_MAGIC
}
EOF

echo ">>> Creating topology.json"

cat > "$CONFIG_DIR/topology.json" <<EOF
{
  "Producers": []
}
EOF

##########################################################################
# CREATE KEYS + ADDRESS + FUND GENESIS
##########################################################################

echo ">>> Generating wallet keys"

cardano-cli address key-gen \
  --verification-key-file "$KEYS_DIR/payment.vkey" \
  --signing-key-file "$KEYS_DIR/payment.skey"

cardano-cli address build \
  --payment-verification-key-file "$KEYS_DIR/payment.vkey" \
  --network-magic $NETWORK_MAGIC \
  > "$KEYS_DIR/payment.addr"

ADDRESS="$(cat $KEYS_DIR/payment.addr)"

echo ">>> Funding genesis UTxO for: $ADDRESS"

# Insert UTxO into genesis
sed -i "s/\"initialFunds\": {}/\"initialFunds\": {\"$ADDRESS\": {\"lovelace\": 1000000000000}}/" "$CONFIG_DIR/genesis.json"

##########################################################################
# START NODE
##########################################################################

echo ">>> Starting cardano-node single node..."

cardano-node run \
  --topology "$CONFIG_DIR/topology.json" \
  --database-path "$DB_DIR" \
  --socket-path "$DB_DIR/node.socket" \
  --host-addr 0.0.0.0 \
  --port $PORT \
  --config "$CONFIG_DIR/node-config.json" \
  --genesis "$CONFIG_DIR/genesis.json" \
  > "$BASE_DIR/node.log" 2>&1 &

echo ""
echo "======================"
echo " CARDANO NODE STARTED"
echo "======================"
echo "Address funded with 1,000,000 ADA:"
echo "$ADDRESS"
echo ""
echo "Logs: $BASE_DIR/node.log"
echo "Socket: $DB_DIR/node.socket"
echo ""
echo "Tailing logs..."
tail -f "$BASE_DIR/node.log"