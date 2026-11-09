#!/usr/bin/env bash
# Shows which enterprise test rig services (ADR-0039) are running and where.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "usage: scripts/testing/enterprise-rig/status.sh   (state: $RIG_DIR)"
    exit 0
fi

services="$(rig_services)"
if [[ -z "$services" ]]; then
    echo "rig is not running (state: $RIG_DIR)"
    exit 1
fi
running=0
for service in $services; do
    if pid="$(rig_pid "$service")"; then
        ports="$(awk '$1 == "READY" { printf "%s%s:%s", sep, $3, $2; sep=" " }' "$RIG_LOGS/$service.out" 2>/dev/null || true)"
        [[ "$service" == sshd ]] && ports="ssh:$(awk '$1 == "Port" { print $2 }' "$RIG_DIR/ssh/sshd_config")"
        printf '  %-13s running  pid %-7s %s\n' "$service" "$pid" "$ports"
        running=$((running + 1))
    else
        printf '  %-13s stopped\n' "$service"
    fi
done
echo "state: $RIG_DIR  (env: $RIG_DIR/rig.env)"
((running > 0))
