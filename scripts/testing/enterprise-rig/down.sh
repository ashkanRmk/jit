#!/usr/bin/env bash
# Stops everything the enterprise test rig started (ADR-0039). Keeps the state directory unless --clean.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

clean=0
case "${1:-}" in
    -h | --help)
        echo "usage: scripts/testing/enterprise-rig/down.sh [--clean]"
        echo "  --clean  also delete the state directory ($RIG_DIR): certificates, keys, repositories, logs"
        exit 0 ;;
    --clean) clean=1 ;;
    "") ;;
    *) die "unexpected argument '$1' (see -h)" ;;
esac

for service in $(rig_services); do
    if pid="$(rig_pid "$service")"; then
        kill -TERM "$pid" 2>/dev/null || true
        for _ in $(seq 50); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
            info "stopped $service (pid $pid, killed)"
        else
            info "stopped $service (pid $pid)"
        fi
    fi
    rm -f "$RIG_RUN/$service.pid"
done
rm -f "$RIG_DIR/ssh/sshd.pid"

if ((clean)); then
    if [[ -f "$RIG_MARKER" ]]; then
        rm -rf "$RIG_DIR"
        info "removed $RIG_DIR"
    elif [[ -e "$RIG_DIR" ]]; then
        die "$RIG_DIR has no .jit-rig marker; not deleting it"
    fi
fi
