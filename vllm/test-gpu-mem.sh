#!/usr/bin/env bash
# Standalone test for gpu_mem.py (per-model --gpu-memory-utilization sizing).
# No GPU needed: weights are sparse files in a scratch HF cache and the GPU
# size comes from --total-gib / --free-gib. Run directly:
#   ./test-gpu-mem.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0

# mk_model <repo> <file:GiB>...   (sparse files under snapshots/<hash>/)
mk_model() {
    local repo="$1"; shift
    local d="$tmp/hf/hub/models--${repo/\//--}/snapshots/abc123"
    mkdir -p "$d"
    local spec
    for spec in "$@"; do
        local name="${spec%%:*}" mib="${spec##*:}"
        mkdir -p "$(dirname "$d/$name")"
        truncate -s "${mib}M" "$d/$name"
    done
}
# run <repo> [extra args…] → stdout value; stderr to $tmp/err
run() {
    local repo="$1"; shift
    python3 -I "$SCRIPT_DIR/gpu_mem.py" --model "$repo" --hf-home "$tmp/hf" --total-gib 120 "$@" 2>"$tmp/err"
}
check() { # check <label> <expected> <actual>
    if [[ "$2" != "$3" ]]; then echo "FAIL: $1 — expected '$2', got '$3'"; fail=1; fi
}

# tiny (1.6 GiB): 1.6*1.25 + 8 = 10 GiB of 120 → 0.09 (rounded up)
mk_model org/tiny model.safetensors:1638
check "tiny model" 0.09 "$(run org/tiny)"

# mid (54 GiB, 3 shards): 54*1.25 + 8 = 75.5 → 0.63
mk_model org/mid model-00001.safetensors:18432 model-00002.safetensors:18432 model-00003.safetensors:18432
check "mid model" 0.63 "$(run org/mid)"

# large (65 GiB): 65*1.25 + 8 = 89.25 → 0.75, and bigger than mid
mk_model org/large model-00001.safetensors:33280 model-00002.safetensors:33280
check "large model" 0.75 "$(run org/large)"

# subdirectories are other copies of the weights (gpt-oss: original/, metal/)
# and a consolidated.safetensors next to shards is a duplicate: neither counts.
mk_model org/dupes model-00001.safetensors:1638 original/model.safetensors:1638 \
                   metal/model.bin:1638 consolidated.safetensors:1638
check "duplicate copies ignored" 0.09 "$(run org/dupes)"

# .bin is used when there is no safetensors
mk_model org/binonly pytorch_model.bin:1638
check ".bin fallback" 0.09 "$(run org/binonly)"

# SCALE / BASE_GIB are tunable, both by flag and env
check "scale flag" 0.52 "$(run org/mid --scale 1.0 --base-gib 8)"
check "env knobs" 0.13 "$(VLLM_GPU_MEM_SCALE=2 VLLM_GPU_MEM_BASE_GIB=12 run org/tiny)"

# clamped to [0.05, 0.95]
mk_model org/huge model.safetensors:204800
check "upper clamp" 0.95 "$(run org/huge)"
check "lower clamp" 0.05 "$(run org/tiny --base-gib 0 --scale 0)"

# warns (but still prints a value) when less is free than requested
out=$(run org/mid --free-gib 40)
check "low-free still prints" 0.63 "$out"
if ! grep -q 'only 40.0 GiB is free' "$tmp/err"; then echo "FAIL: no low-free warning"; fail=1; fi
run org/mid --free-gib 100 >/dev/null
if grep -q 'warning' "$tmp/err"; then echo "FAIL: unexpected warning when memory is free"; fail=1; fi

# the reasoning is logged to stderr, stdout stays the bare value
run org/tiny >/dev/null
if ! grep -q 'weights 1.6 GiB (local HF cache)' "$tmp/err"; then echo "FAIL: sizing not logged: $(cat "$tmp/err")"; fail=1; fi

# a local model directory is sized in place
mkdir -p "$tmp/localmodel" && truncate -s 1638M "$tmp/localmodel/model.safetensors"
check "local directory" 0.09 "$(run "$tmp/localmodel")"

# bad knobs fail with a one-line message, not a traceback, and print no value
for bad in abc -1 nan 0x; do
    if out=$(VLLM_GPU_MEM_SCALE=$bad run org/tiny 2>/dev/null); then rc=0; else rc=$?; fi
    check "bad scale '$bad' exit code" 2 "$rc"
    check "bad scale '$bad' stdout" "" "$out"
    if grep -q Traceback "$tmp/err"; then echo "FAIL: bad scale '$bad' dumped a traceback"; fail=1; fi
done
if out=$(python3 -I "$SCRIPT_DIR/gpu_mem.py" --model org/tiny --hf-home "$tmp/hf" --total-gib 0 2>"$tmp/err"); then rc=0; else rc=$?; fi
check "zero GPU total exit code" 2 "$rc"

# unknown model (not cached; Hub unreachable/unknown) → exit 1, no stdout,
# so the entrypoint can fall back instead of passing garbage to vLLM.
if out=$(HF_HUB_OFFLINE=1 run org/missing 2>/dev/null); then rc=0; else rc=$?; fi
check "unknown model exit code" 1 "$rc"
check "unknown model stdout" "" "$out"

# --- entrypoint.sh wiring: stub `vllm` (prints its argv) and the helper ---
bin="$tmp/bin"; mkdir -p "$bin"
printf '#!/usr/bin/env bash\necho "vllm-args: $*"\n' > "$bin/vllm"; chmod +x "$bin/vllm"
sed -e "s|/usr/local/bin/vllm-gpu-mem|$bin/helper|" -e "s|/usr/local/bin/vllm-model-kind|$bin/kind|" \
    "$SCRIPT_DIR/entrypoint.sh" > "$bin/entrypoint.sh"
chmod +x "$bin/entrypoint.sh"
# ep <helper stdout> <helper exit> [VAR=val…] → entrypoint output
ep() {
    local out="$1" rc="$2"; shift 2
    printf 'import sys, pathlib\npathlib.Path("%s/called").touch()\nif %s: print(%s)\nsys.exit(%s)\n' \
        "$tmp" "$([[ -n $out ]] && echo True || echo False)" "\"$out\"" "$rc" > "$bin/helper"
    rm -f "$tmp/called"
    env -i PATH="$bin:/usr/bin:/bin" VLLM_MODEL=org/tiny "$@" bash "$bin/entrypoint.sh" 2>&1
}
gm() { grep -o -e '--gpu-memory-utilization [0-9.]*' <<<"$1" | awk 'NR==1{print $2}'; }

o=$(ep 0.09 0);                   check "entrypoint auto-sizes"       0.09 "$(gm "$o")"
o=$(ep 0.09 0 VLLM_GPU_MEM=0.4);  check "explicit pin wins"           0.4  "$(gm "$o")"
[[ ! -e "$tmp/called" ]] || { echo "FAIL: helper must not run when VLLM_GPU_MEM is pinned"; fail=1; }
o=$(ep 0.09 0 VLLM_GPU_MEM=);     check "empty pin → auto-size"       0.09 "$(gm "$o")"
o=$(ep "" 1);                     check "helper failure → fallback"   0.9  "$(gm "$o")"
grep -q 'sizing failed' <<<"$o" || { echo "FAIL: fallback not announced"; fail=1; }
o=$(ep "oops" 0);                 check "garbage output → fallback"   0.9  "$(gm "$o")"
o=$(ep "1.5" 0);                  check "out-of-format → fallback"    0.9  "$(gm "$o")"

# --- tool parser: unset → ask vLLM (model_kind.py); explicit values are final ---
# ek <kind stdout> <exit> [VAR=val…] → entrypoint output; the sizing step is pinned off.
ek() {
    local out="$1" rc="$2"; shift 2
    printf 'import sys, pathlib\npathlib.Path("%s/kind-called").touch()\nif %s: print(%s)\nsys.exit(%s)\n' \
        "$tmp" "$([[ -n $out ]] && echo True || echo False)" "\"$out\"" "$rc" > "$bin/kind"
    rm -f "$tmp/kind-called"
    env -i PATH="$bin:/usr/bin:/bin" VLLM_MODEL=org/m VLLM_GPU_MEM=0.5 "$@" bash "$bin/entrypoint.sh" 2>&1
}
tp() { grep -o -e '--tool-call-parser [a-z0-9_]*' <<<"$1" | awk 'NR==1{print $2}'; }

o=$(ek chat 0);              check "chat → qwen3_xml"            qwen3_xml     "$(tp "$o")"
o=$(ek transcription 0);     check "transcription → no parser"   ""            "$(tp "$o")"
grep -q -e '--enable-auto-tool-choice' <<<"$o" && { echo "FAIL: transcription must not enable auto tool choice"; fail=1; }
o=$(ek pooling 0);           check "pooling → no parser"         ""            "$(tp "$o")"
o=$(ek "" 1);                check "probe fails → chat default"  qwen3_xml     "$(tp "$o")"
grep -q 'could not classify' <<<"$o" || { echo "FAIL: probe failure not announced"; fail=1; }
o=$(ek "banana" 0);          check "garbage kind → chat default" qwen3_xml     "$(tp "$o")"
o=$(ek transcription 0 VLLM_TOOL_PARSER=auto); check "explicit auto probes" ""   "$(tp "$o")"
o=$(ek transcription 0 VLLM_TOOL_PARSER=hermes); check "named parser wins" hermes "$(tp "$o")"
[[ ! -e "$tmp/kind-called" ]] || { echo "FAIL: probe must not run when a parser is named"; fail=1; }
o=$(ek chat 0 VLLM_TOOL_PARSER=);                check "empty → off"  ""           "$(tp "$o")"
[[ ! -e "$tmp/kind-called" ]] || { echo "FAIL: probe must not run when the parser is forced off"; fail=1; }

# classify(): transcription beats pooling beats chat (Whisper is also a "generate" runner)
for case in "True True transcription" "True False transcription" "False True pooling" "False False chat"; do
    set -- $case
    check "classify($1,$2)" "$3" "$(python3 -I -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR')
from model_kind import classify; print(classify($1, $2))")"
done

if [[ $fail -eq 0 ]]; then
    echo "PASS: gpu_mem.py (sizing + duplicate weights + local dirs + knob validation + clamps + warnings + entrypoint sizing + tool-parser wiring/fallback)"
else
    exit 1
fi
