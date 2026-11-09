#!/usr/bin/env bash
# Checks the bundled Git runtime (ADR-0019).
#
#   scripts/build/test-bundled-git.sh [--network] [--suite] [git-runtime-dir]
#
# Default: copies the runtime to a random path containing a space, then exercises it there (version,
# exec-path inside the copy, isolated system config, init/commit/branch/merge/rebase/cherry-pick/revert/
# stash, file:// clone and fetch). --network adds `git ls-remote https://github.com/git/git` (system
# libcurl + system trust). --suite also runs the whole JitKit test suite with JIT_GIT_PATH pointing at
# the relocated copy and GIT_TRACE captured, and fails on any missing-helper message in the trace.
source "$(dirname "$0")/common.sh"
source "$(dirname "$0")/git-version.env"

NETWORK=0; SUITE=0; RUNTIME=""
for arg in "$@"; do
    case "$arg" in
        --network) NETWORK=1 ;;
        --suite) SUITE=1 ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) RUNTIME="$arg" ;;
    esac
done
RUNTIME="${RUNTIME:-$REPO_ROOT/build/git-runtime/$GIT_VERSION/git}"
[[ -x "$RUNTIME/bin/git" ]] || die "no Git runtime at $RUNTIME (run scripts/build/build-git.sh)"

WORK="$(cd "$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/jit-bundled-git.XXXXXX")" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
COPY="$WORK/relocated copy/git"
mkdir -p "$(dirname "$COPY")"
cp -R "$RUNTIME" "$COPY"
GIT="$COPY/bin/git"
failures=0
check() { # description, command...
    local desc="$1"; shift
    if "$@" >"$WORK/out" 2>&1; then echo "  ok   $desc"; else echo "  FAIL $desc"; sed 's/^/       /' "$WORK/out"; failures=$((failures + 1)); fi
}
expect_eq() { [[ "$1" == "$2" ]] || { echo "expected '$2', got '$1'"; return 1; }; }

export HOME="$WORK/home" GIT_CONFIG_GLOBAL="$WORK/home/.gitconfig" GIT_TERMINAL_PROMPT=0 LC_ALL=C
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$HOME"
printf '[user]\n\tname = Jit Release\n\temail = release@jit.invalid\n[init]\n\tdefaultBranch = main\n' >"$GIT_CONFIG_GLOBAL"

info "Relocated runtime: $COPY"
check "version is $GIT_VERSION" expect_eq "$("$GIT" --version)" "git version $GIT_VERSION"
check "exec-path resolves inside the copy" expect_eq "$("$GIT" --exec-path)" "$COPY/libexec/git-core"
check "built without Rust, Perl, Python" sh -c "'$GIT' version --build-options | grep -q 'rust: disabled'"
check "links only system libraries" sh -c "! otool -L '$GIT' '$COPY/libexec/git-core/git-remote-http' | grep -E '/opt/homebrew|/usr/local|@rpath'"
check "system config is the bundled empty file" sh -c "'$GIT' config --system --list --show-origin; test -z \"\$('$GIT' config --system --list)\""
check "global config is respected" expect_eq "$("$GIT" config user.name)" "Jit Release"

R="$WORK/repo"
check "init + commit" sh -c "'$GIT' init -q '$R' && cd '$R' && echo a > a && '$GIT' add a && '$GIT' commit -qm one"
check "branch + merge (ort)" sh -c "cd '$R' && '$GIT' switch -qc topic && echo b > b && '$GIT' add b && '$GIT' commit -qm two && '$GIT' switch -q main && echo c > c && '$GIT' add c && '$GIT' commit -qm three && '$GIT' merge -q --no-edit topic"
check "merge-tree --write-tree" sh -c "cd '$R' && '$GIT' merge-tree --write-tree main topic >/dev/null"
check "octopus merge (shell strategy)" sh -c "cd '$R' && '$GIT' branch o1 HEAD~1 && '$GIT' branch o2 HEAD~1 && '$GIT' switch -q o1 && echo x > x && '$GIT' add x && '$GIT' commit -qm x && '$GIT' switch -q o2 && echo y > y && '$GIT' add y && '$GIT' commit -qm y && '$GIT' switch -q main && '$GIT' merge -q --no-edit o1 o2"
check "merge -s resolve (shell strategy)" sh -c "cd '$R' && '$GIT' switch -qc r1 && echo r > r && '$GIT' add r && '$GIT' commit -qm r && '$GIT' switch -q main && '$GIT' merge -q --no-edit -s resolve r1"
check "rebase" sh -c "cd '$R' && '$GIT' switch -qc rb HEAD~2 && echo d > d && '$GIT' add d && '$GIT' commit -qm four && '$GIT' rebase -q main"
check "cherry-pick + revert" sh -c "cd '$R' && '$GIT' switch -q main && '$GIT' cherry-pick rb >/dev/null && '$GIT' revert --no-edit HEAD >/dev/null"
check "stash" sh -c "cd '$R' && echo e >> a && '$GIT' stash -q && '$GIT' stash pop -q"
check "file:// clone + fetch" sh -c "'$GIT' clone -q 'file://$R' '$WORK/clone' && cd '$WORK/clone' && '$GIT' fetch -q origin"
check "local path clone (upload-pack)" sh -c "'$GIT' clone -q --no-local '$R' '$WORK/clone2'"
check "submodule add (shell helper)" sh -c "cd '$R' && '$GIT' -c protocol.file.allow=always submodule --quiet add '$WORK/clone2' sub"
if [[ $NETWORK -eq 1 ]]; then
    check "https ls-remote (system libcurl)" sh -c "'$GIT' ls-remote https://github.com/git/git HEAD | grep -q HEAD"
fi

if [[ $SUITE -eq 1 ]]; then
    info "JitKit test suite against the relocated runtime"
    TRACE="$WORK/git-trace.log"
    : >"$TRACE"
    if JIT_GIT_PATH="$GIT" JIT_TEST_GIT_TRACE="$TRACE" JIT_FULL_SUITE=1 \
        swift test --package-path "$PACKAGE_DIR" >"$WORK/suite.log" 2>&1; then
        echo "  ok   swift test ($(grep -hoE 'Test run with [0-9]+ tests' "$WORK/suite.log" | awk '{s+=$4} END {print s}') tests)"
    else
        echo "  FAIL swift test"; grep -E "✘|error:" "$WORK/suite.log" | head -40 | sed 's/^/       /'
        cp "$WORK/suite.log" "$REPO_ROOT/build/bundled-git-suite.log"; failures=$((failures + 1))
    fi
    used="$(grep -hoE "trace: (exec|run_command|built-in): git[ -][a-z0-9-]+" "$TRACE" | awk '{print $NF}' | sed 's/^git-//' | sort -u | tr '\n' ' ')"
    echo "  Git subcommands seen: $used"
    if grep -hE "is not a git command|cannot exec|No such file or directory.*git-core|not found" "$TRACE" | head -5 | grep -q .; then
        echo "  FAIL missing helper in GIT_TRACE"; failures=$((failures + 1))
    else
        echo "  ok   no missing-helper messages in $(wc -l <"$TRACE" | tr -d ' ') trace lines"
    fi
    [[ "$(grep -c "$COPY" "$TRACE")" -gt 0 ]] && echo "  ok   trace shows the relocated runtime in use" \
        || { echo "  FAIL trace does not mention the relocated runtime"; failures=$((failures + 1)); }
fi

[[ $failures -eq 0 ]] || die "$failures check(s) failed"
info "Bundled Git checks passed"
