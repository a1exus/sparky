#!/usr/bin/env bash
# Asserts on the rendered compose config — no GPU or image pull needed.
set -euo pipefail
cd "$(dirname "$0")"

fails=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }

# --env-file /dev/null keeps a developer's real .env out of the assertions.
render() { env "$@" docker compose --env-file /dev/null config --format json; }
svc() { jq -rc ".services.pytorch | $1" <<<"$cfg"; }
check() { # name, jq expression (relative to the service), expected
    local got; got=$(svc "$2")
    [[ "$got" == "$3" ]] && pass "$1" || fail "$1" "$2 = $got, want $3"
}

if err=$(env -u PYTORCH_TAG docker compose --env-file /dev/null config 2>&1 >/dev/null); then
    fail tag_required "config succeeded without PYTORCH_TAG"
elif grep -q PYTORCH_TAG <<<"$err"; then
    pass tag_required
else
    fail tag_required "error does not name PYTORCH_TAG: $err"
fi

cfg=$(render PYTORCH_TAG=test)
check image '.image' 'nvcr.io/nvidia/pytorch:test'
check restart '.restart' 'no'
check ipc '.ipc' 'host'
check init '.init' 'true'
check no_new_privileges '.security_opt' '["no-new-privileges:true"]'
check shm_size '.shm_size' '17179869184'
check gpu_driver '.deploy.resources.reservations.devices[0].driver' 'nvidia'
# compose renders `count: all` as -1
check gpu_count '.deploy.resources.reservations.devices[0].count' '-1'
check gpu_caps '.deploy.resources.reservations.devices[0].capabilities' '["gpu"]'
check no_ports '(.ports // []) | length' '0'
check no_labels '(.labels // {}) | length' '0'
check no_traefik_network '(.networks // {}) | has("traefik")' 'false'
check user_default '.user' '1000:1000'
check hf_home '.environment.HF_HOME' '/hf'
# torch.compile and getpass.getuser() break for a UID with no passwd entry.
check inductor_cache '.environment.TORCHINDUCTOR_CACHE_DIR' '/cache/inductor'
check user_env '.environment.USER' 'pytorch'

targets=$(svc '.volumes | map(.target) | sort | join(",")')
for t in /workspace /hf /cache; do
    [[ ",$targets," == *",$t,"* ]] && pass "mount $t" || fail "mount $t" "targets: $targets"
done

cfg=$(render PYTORCH_TAG=test PYTORCH_UID=1234 PYTORCH_GID=5678)
check user_override '.user' '1234:5678'

((fails == 0)) || { echo "$fails failure(s)"; exit 1; }
