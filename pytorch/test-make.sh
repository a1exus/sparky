#!/usr/bin/env bash
# Drives the Makefile against a stub `docker` that logs its argv, so no
# daemon, GPU or image is needed.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)

fails=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2"; fails=$((fails + 1)); }

# Fresh sandbox per case. STUB_RUNNING lists containers `docker ps` reports up.
sandbox() {
    T=$(mktemp -d)
    mkdir "$T/bin"
    cp "$here/Makefile" "$here/docker-compose.yml" "$here/.env.example" "$T/"
    cat >"$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $* [uid=${PYTORCH_UID:-} gid=${PYTORCH_GID:-}]" >>"$STUB_LOG"
if [[ "${1:-}" == ps ]]; then
    for name in $STUB_RUNNING; do
        [[ "$*" == *"name=^$name\$"* ]] && echo "id-$name"
    done
fi
exit 0
STUB
    chmod +x "$T/bin/docker"
    : >"$T/stub.log"
}

# run_make [VAR=val ...] -- make args; sets $out and $rc.
run_make() {
    local running=$1; shift
    out=$(cd "$T" && PATH="$T/bin:$PATH" STUB_LOG="$T/stub.log" STUB_RUNNING="$running" make "$@" 2>&1) && rc=0 || rc=$?
}
logged() { grep -c -- "$1" "$T/stub.log" || true; }

sandbox
run_make "" up
[[ $rc -ne 0 ]] && grep -q PYTORCH_TAG <<<"$out" && [[ -f "$T/.env" ]] && [[ $(logged 'compose') -eq 0 ]] \
    && pass up_creates_env_and_demands_tag || fail up_creates_env_and_demands_tag "rc=$rc out=$out"

sandbox
echo 'PYTORCH_TAG=x' >"$T/.env"
run_make "" up
[[ $rc -eq 0 && -d "$T/workspace" && -d "$T/cache" && $(logged ' up -d') -eq 1 ]] \
    && pass up_creates_dirs || fail up_creates_dirs "rc=$rc out=$out"

sandbox
echo 'PYTORCH_TAG=x' >"$T/.env"
run_make "vllm" up
[[ $rc -eq 0 ]] && grep -q vllm <<<"$out" && [[ $(logged ' stop') -eq 0 && $(logged ' down') -eq 0 && $(logged ' up -d') -eq 1 ]] \
    && pass up_warns_when_gpu_busy || fail up_warns_when_gpu_busy "rc=$rc out=$out"

sandbox
run_make "pytorch" run
[[ $rc -ne 0 ]] && grep -q 'usage: make run CMD=' <<<"$out" && [[ $(logged ' exec ') -eq 0 ]] \
    && pass run_requires_cmd || fail run_requires_cmd "rc=$rc out=$out"

sandbox
run_make "pytorch" run CMD="python -c 'print(1 + 1)'"
[[ $rc -eq 0 && $(logged "exec pytorch bash -lc python -c 'print(1 + 1)'") -eq 1 ]] \
    && pass run_passes_cmd_intact || fail run_passes_cmd_intact "rc=$rc log=$(cat "$T/stub.log")"

for target in shell "run CMD=x" check; do
    sandbox
    # shellcheck disable=SC2086
    run_make "" $target
    [[ $rc -ne 0 ]] && grep -q 'make up' <<<"$out" && [[ $(logged ' exec ') -eq 0 ]] \
        && pass "needs_up ($target)" || fail "needs_up ($target)" "rc=$rc out=$out"
done

sandbox
run_make "pytorch" check
[[ $rc -eq 0 && $(logged 'exec -T pytorch python -c') -eq 1 ]] \
    && pass check_runs_python_in_container || fail check_runs_python_in_container "rc=$rc log=$(cat "$T/stub.log")"

sandbox
echo 'PYTORCH_TAG=x' >"$T/.env"
run_make "" up
want="uid=$(id -u) gid=$(id -g)"
[[ $(logged " up -d \[$want\]") -eq 1 ]] \
    && pass uid_gid_exported || fail uid_gid_exported "log=$(cat "$T/stub.log")"

((fails == 0)) || { echo "$fails failure(s)"; exit 1; }
