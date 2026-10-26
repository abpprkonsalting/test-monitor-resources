#!/usr/bin/env bash
# test-monitor-resources.sh
# Test harness for monitor-resources.sh. Creates dummy systemd services,
# runs monitoring scenarios, and produces a report. Does NOT modify monitor-resources.sh.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MONITOR="$SCRIPT_DIR/monitor-resources.sh"
REPORT="$SCRIPT_DIR/test-report.txt"
WORKDIR="/tmp/monitor-test-$$"
mkdir -p "$WORKDIR"

: > "$REPORT"
FAIL_COUNT=0
PASS_COUNT=0

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }

record() {
    local status="$1"; shift
    if [[ "$status" == PASS ]]; then PASS_COUNT=$((PASS_COUNT+1)); else FAIL_COUNT=$((FAIL_COUNT+1)); fi
    printf '[%s] %s\n' "$status" "$*" | tee -a "$REPORT"
}

cleanup() {
    # stop and remove dummy services
    for svc in $(systemctl list-unit-files 'monitor-test-*.service' --no-legend 2>/dev/null | awk '{print $1}'); do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        rm -f "/etc/systemd/system/$svc" 2>/dev/null || true
    done
    systemctl daemon-reload 2>/dev/null || true
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

create_services() {
    local n="$1"
    local i
    for ((i=1; i<=n; i++)); do
        local name="monitor-test-${i}.service"
        cat > "$WORKDIR/worker.sh" <<'WORKER'
#!/usr/bin/env bash
# Light, realistic load: modest memory + intermittent CPU.
while :; do
    n=$(( RANDOM % 5000 + 500 ))
    unset arr
    declare -a arr
    for ((i=0;i<n;i++)); do arr[i]="line-$i-$(date +%s%N)"; done
    # light CPU: hash the array once
    printf '%s\n' "${arr[@]}" | sha256sum >/dev/null 2>&1 || true
    sleep $(( RANDOM % 3 + 1 ))
done
WORKER
        chmod +x "$WORKDIR/worker.sh"
        cat > "/etc/systemd/system/$name" <<EOF
[Unit]
Description=Monitor test dummy process $i
[Service]
ExecStart=$WORKDIR/worker.sh
Restart=always
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable --now "$name" >/dev/null 2>&1
    done
}

remove_services() {
    local i
    for svc in $(systemctl list-unit-files 'monitor-test-*.service' --no-legend 2>/dev/null | awk '{print $1}'); do
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        rm -f "/etc/systemd/system/$svc"
    done
    systemctl daemon-reload 2>/dev/null || true
}

run_case() {
    local desc="$1"; shift
    local logfile="$WORKDIR/mon.log"
    rm -f "$logfile" "$logfile".* "${logfile%.log}.csv" 2>/dev/null
    # run monitor for ~2 intervals then SIGTERM
    timeout 7 "$MONITOR" "$@" -o "$logfile" -csv 2>"$WORKDIR/err.txt" &
    local mpid=$!
    # include own process pid? handled by caller passing selectors
    wait $mpid 2>/dev/null || true
    if [[ -f "${logfile%.log}.csv" ]]; then
        record PASS "$desc"
    else
        record FAIL "$desc (no CSV produced)"
        cat "$WORKDIR/err.txt" >> "$REPORT"
    fi
}

# Scenario matrix
for n in 1 2 5 10; do
    log "=== Run with $n monitored processes ==="
    create_services "$n"
    # build selector list
    selectors=()
    for ((i=1; i<=n; i++)); do selectors+=("monitor-test-${i}.service"); done
    if (( n > 1 )); then
        # include own shell process running monitor: use current shell pid as numeric selector
        selectors+=("$$")
    fi

    # basic
    run_case "basic ($n svc)" -i 2 "${selectors[@]}"

    # csv without -o should fail
    if timeout 3 "$MONITOR" -csv "${selectors[@]}" >/dev/null 2>&1; then
        record FAIL "csv-without-o should have failed ($n)"
    else
        record PASS "csv-without-o fails as expected ($n)"
    fi

    # invalid selector
    run_case "invalid-selector ($n)" -i 2 "${selectors[@]}" nonexistent-proc-xyz

    # numeric pid selector already included via $$

    # append mode: pre-create log then run with 'A'
    logfile="$WORKDIR/append.log"
    printf 'old line\n' > "$logfile"
    printf 'A\n' | timeout 7 "$MONITOR" -i 2 -o "$logfile" -csv "${selectors[@]}" >/dev/null 2>&1 || true
    if [[ -f "${logfile%.log}.csv" ]]; then record PASS "append-mode ($n)"; else record FAIL "append-mode ($n)"; fi

    # overwrite mode
    logfile="$WORKDIR/over.log"
    printf 'old line\n' > "$logfile"
    printf 'O\n' | timeout 7 "$MONITOR" -i 2 -o "$logfile" -csv "${selectors[@]}" >/dev/null 2>&1 || true
    if [[ -f "${logfile%.log}.csv" ]]; then record PASS "overwrite-mode ($n)"; else record FAIL "overwrite-mode ($n)"; fi

    # small rotation
    logfile="$WORKDIR/rot.log"
    rm -f "$logfile" "$logfile".*
    timeout 7 "$MONITOR" -i 1 -s 4K -r 3 -o "$logfile" -csv "${selectors[@]}" >/dev/null 2>&1 || true
    if [[ -f "${logfile%.log}.csv" ]]; then record PASS "rotation ($n)"; else record FAIL "rotation ($n)"; fi

    # max rotations 0
    logfile="$WORKDIR/rot0.log"
    rm -f "$logfile" "$logfile".*
    timeout 7 "$MONITOR" -i 1 -s 2K -r 0 -o "$logfile" -csv "${selectors[@]}" >/dev/null 2>&1 || true
    if [[ -f "${logfile%.log}.csv" ]]; then record PASS "rotations-zero ($n)"; else record FAIL "rotations-zero ($n)"; fi

    remove_services
done

log "=== Summary ==="
log "PASS: $PASS_COUNT  FAIL: $FAIL_COUNT"
log "Full report: $REPORT"
