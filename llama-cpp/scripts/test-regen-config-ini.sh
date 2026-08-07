#!/usr/bin/env bash
# Standalone test for regen-config-ini.py. No framework — builds a scratch
# dir, runs the script, asserts on the resulting files. Run directly:
#   ./scripts/test-regen-config-ini.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGEN="$SCRIPT_DIR/regen-config-ini.py"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

farm="$tmp/farm"
mkdir -p "$farm"
touch "$farm/auto-model.gguf"
touch "$farm/manual-model.gguf"
# gone-model.gguf intentionally NOT created — simulates a removed GGUF.

fail=0

# --- scenario 1: hand-added section preservation + orphan archival ---
config="$tmp/config.ini"
orphans="$tmp/config.ini.orphans"
collisions="$tmp/collisions.txt"
: > "$collisions"

cat > "$config" <<'EOF'
[auto-model]
model = /models/auto-model.gguf
ctx-size = 4096

[manual-alias]
model = /models/manual-model.gguf
ctx-size = 16384

[gone-model]
model = /models/gone-model.gguf
EOF

printf 'auto-model\t/models/auto-model.gguf\n' | "$REGEN" "$config" "$orphans" 8192 999 "$farm" "$collisions"

if ! grep -q '^\[auto-model\]' "$config"; then
    echo "FAIL: [auto-model] missing from config.ini (should be managed+kept)"; fail=1
fi
if ! grep -q 'ctx-size = 4096' "$config"; then
    echo "FAIL: [auto-model] lost its user-set ctx-size"; fail=1
fi
if ! grep -q '^\[manual-alias\]' "$config"; then
    echo "FAIL: [manual-alias] missing from config.ini — hand-added section not preserved"; fail=1
fi
if ! grep -q 'ctx-size = 16384' "$config"; then
    echo "FAIL: [manual-alias] lost its user-set ctx-size"; fail=1
fi
if grep -q '^\[gone-model\]' "$config"; then
    echo "FAIL: [gone-model] still in config.ini — should have been archived (its GGUF is gone)"; fail=1
fi
if ! grep -q '^\[gone-model\]' "$orphans"; then
    echo "FAIL: [gone-model] not archived to config.ini.orphans"; fail=1
fi

# --- scenario 2: COLLISIONS header rendering ---
config2="$tmp/config2.ini"
orphans2="$tmp/config2.ini.orphans"
collisions2="$tmp/collisions2.txt"
printf 'model-x.gguf\tvendorA/Model-X-GGUF,vendorB/Model-X-GGUF\n' > "$collisions2"

printf 'vendora-model-x-gguf--model-x\t/models/vendora-model-x-gguf--model-x.gguf\nvendorb-model-x-gguf--model-x\t/models/vendorb-model-x-gguf--model-x.gguf\n' \
    | "$REGEN" "$config2" "$orphans2" 8192 999 "$farm" "$collisions2"

if ! grep -q '# COLLISIONS' "$config2"; then
    echo "FAIL: config.ini missing COLLISIONS header block"; fail=1
fi
if ! grep -q 'model-x.gguf' "$config2"; then
    echo "FAIL: COLLISIONS header doesn't mention the colliding basename"; fail=1
fi

if [[ $fail -eq 0 ]]; then
    echo "PASS: regen-config-ini.py"
else
    exit 1
fi
