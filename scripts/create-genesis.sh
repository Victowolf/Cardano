#!/usr/bin/env bash
set -euo pipefail


CONFIG_DIR="${1:-$(pwd)/config}"
BASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$CONFIG_DIR/genesis.json.template"
OUT="$BASE_DIR/genesis.json"


if [ ! -f "$TEMPLATE" ]; then
echo "ERROR: genesis template not found at $TEMPLATE" >&2
exit 1
fi


# replace placeholders with sane defaults if missing
SYSTEM_START=${SYSTEM_START:-"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
NETWORK_MAGIC=${NETWORK_MAGIC:-42}


cp "$TEMPLATE" "$OUT"


# naive substitutions (safe for the placeholders used in template)
sed -i "s/__SYSTEM_START_ISO__/$SYSTEM_START/g" "$OUT"
sed -i "s/__NETWORK_MAGIC__/$NETWORK_MAGIC/g" "$OUT"


echo "Generated genesis at $OUT"