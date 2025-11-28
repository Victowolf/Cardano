#!/usr/bin/env bash
set -euo pipefail


CONFIG_DIR="${1:-$(pwd)/config}"
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KEYS_DIR="$BASE_DIR/keys"
mkdir -p "$KEYS_DIR"


. "$BASE_DIR/scripts/common.sh"


PAY_VKEY="$KEYS_DIR/payment.vkey"
PAY_SKEY="$KEYS_DIR/payment.skey"
PAY_ADDR="$KEYS_DIR/payment.addr"


# generate keys
if [ ! -f "$PAY_VKEY" ] || [ ! -f "$PAY_SKEY" ]; then
echo "Generating payment keypair..."
$CARDANO_CLI_BIN address key-gen \
--verification-key-file "$PAY_VKEY" \
--signing-key-file "$PAY_SKEY"
else
echo "Payment keypair already exists."
fi


# generate address
if [ ! -f "$PAY_ADDR" ]; then
echo "Building payment address..."
$CARDANO_CLI_BIN address build \
--payment-verification-key-file "$PAY_VKEY" \
--network-magic $NETWORK_MAGIC \
> "$PAY_ADDR"
fi


echo "Payment address: $(cat $PAY_ADDR)"


# Add the generated address into genesis (naive step)
GENESIS_JSON="$BASE_DIR/genesis.json"
if [ -f "$GENESIS_JSON" ]; then
ADDR=$(cat "$PAY_ADDR")
# This will only work with the very simple genesis template provided earlier.
# Advanced usage: use cardano-cli genesis creation commands.
echo "You should add $ADDR to genesis UTxO entries with a large lovelace amount for initial funds."
fi