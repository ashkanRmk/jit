# Shared helpers for scripts/testing/enterprise-rig/*.sh (ADR-0039). Sourced, not executed.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../build" && pwd)/common.sh"

RIG_DIR="${JIT_RIG_DIR:-$HOME/Library/Caches/jit-rig}"
# Own SwiftPM scratch path so the rig build never contends with the package's default .build lock.
RIG_SCRATCH="${JIT_RIG_SCRATCH:-$HOME/Library/Caches/jit-rig-build}"
RIG_RUN="$RIG_DIR/run"
RIG_LOGS="$RIG_DIR/logs"
RIG_MARKER="$RIG_DIR/.jit-rig"

# Prints the pid in run/<name>.pid if that process is alive and is one the rig started.
rig_pid() {
    local file="$RIG_RUN/$1.pid" pid command
    [[ -f "$file" ]] || return 1
    pid="$(cat "$file")"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    command="$(ps -p "$pid" -o command= 2>/dev/null)" || return 1
    [[ "$command" == *TestRig* || "$command" == *sshd* ]] || return 1
    echo "$pid"
}

rig_services() {
    local file
    for file in "$RIG_RUN"/*.pid; do
        [[ -e "$file" ]] || continue
        basename "$file" .pid
    done
}
