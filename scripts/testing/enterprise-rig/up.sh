#!/usr/bin/env bash
# Starts the dev-only local enterprise test rig (ADR-0039): throwaway CAs and certificates, bare repositories,
# TLS and plain-HTTP git servers with a GitLab API stub, HTTP/SOCKS5 proxies (with and without auth) and a
# user-level sshd. Everything binds to 127.0.0.1 on high ports; nothing touches ~/.ssh, ~/.gitconfig or the
# login keychain. Writes rig.env (shell) and rig.json describing the running rig.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<EOF
usage: scripts/testing/enterprise-rig/up.sh

State directory: \${JIT_RIG_DIR:-~/Library/Caches/jit-rig} (now: $RIG_DIR)
SwiftPM scratch: \${JIT_RIG_SCRATCH:-~/Library/Caches/jit-rig-build}
Certificates, keys and repositories are created once and reused; down.sh --clean removes them.
Then: source "$RIG_DIR/rig.env"  (or read rig.json). Stop with down.sh.
EOF
    exit 0
fi
[[ $# -eq 0 ]] || die "unexpected argument '$1' (see -h)"

for service in $(rig_services); do
    rig_pid "$service" >/dev/null && die "the rig is already running ($service); run down.sh first"
done

OPENSSL=/usr/bin/openssl
SSHD=/usr/sbin/sshd
GIT="$(command -v git)" || die "git not found on PATH"
[[ -x "$SSHD" ]] || die "$SSHD not found"

mkdir -p "$RIG_DIR" "$RIG_RUN" "$RIG_LOGS" "$RIG_DIR/certs" "$RIG_DIR/ssh" "$RIG_DIR/repos"
chmod 700 "$RIG_DIR"
touch "$RIG_MARKER"
rm -f "$RIG_RUN"/*.pid

# ---------------------------------------------------------------------------------------------- build
info "building TestRig"
swift build --package-path "$PACKAGE_DIR" --product TestRig --scratch-path "$RIG_SCRATCH" >"$RIG_LOGS/build.log" 2>&1 \
    || { tail -30 "$RIG_LOGS/build.log" >&2; die "TestRig build failed (log: $RIG_LOGS/build.log)"; }
TESTRIG="$(swift build --package-path "$PACKAGE_DIR" --product TestRig --scratch-path "$RIG_SCRATCH" --show-bin-path)/TestRig"
[[ -x "$TESTRIG" ]] || die "TestRig binary not found at $TESTRIG"

# --------------------------------------------------------------------------------------- certificates
CERTS="$RIG_DIR/certs"
P12_PASSWORD="rig-p12-password"
make_ca() { # <name> <common name>
    local name="$1" cn="$2"
    [[ -f "$CERTS/$name.pem" ]] && return 0
    "$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 -subj "/O=Jit Test Rig/CN=$cn" \
        -keyout "$CERTS/$name.key" -out "$CERTS/$name.pem" \
        -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -addext "subjectKeyIdentifier=hash" 2>>"$RIG_LOGS/openssl.log"
    chmod 600 "$CERTS/$name.key"
}
if [[ ! -f "$CERTS/server.p12" ]]; then
    info "generating throwaway CAs and certificates"
    make_ca ca "Jit Rig Test Root CA"
    make_ca other-ca "Jit Rig Unrelated CA"
    cat >"$CERTS/server.ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,IP:127.0.0.1
authorityKeyIdentifier=keyid
subjectKeyIdentifier=hash
EOF
    "$OPENSSL" req -new -newkey rsa:2048 -sha256 -nodes -subj "/O=Jit Test Rig/CN=localhost" \
        -keyout "$CERTS/server.key" -out "$CERTS/server.csr" 2>>"$RIG_LOGS/openssl.log"
    # 397 days keeps the leaf inside Apple's TLS validity limit.
    "$OPENSSL" x509 -req -sha256 -days 397 -in "$CERTS/server.csr" -CA "$CERTS/ca.pem" -CAkey "$CERTS/ca.key" \
        -CAcreateserial -extfile "$CERTS/server.ext" -out "$CERTS/server.pem" 2>>"$RIG_LOGS/openssl.log"
    "$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -nodes -days 397 -subj "/O=Jit Test Rig/CN=localhost" \
        -keyout "$CERTS/leaf-selfsigned.key" -out "$CERTS/leaf-selfsigned.pem" \
        -addext "basicConstraints=critical,CA:FALSE" -addext "extendedKeyUsage=serverAuth" \
        -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>>"$RIG_LOGS/openssl.log"
    # LibreSSL has no -legacy; 3DES + SHA-1 MAC is what SecPKCS12Import reads (verified when TestRig starts).
    legacy=()
    "$OPENSSL" pkcs12 -help 2>&1 | grep -q -- '-legacy' && legacy=(-legacy)
    "$OPENSSL" pkcs12 -export ${legacy[@]+"${legacy[@]}"} -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
        -name "jit-rig-server" -inkey "$CERTS/server.key" -in "$CERTS/server.pem" -certfile "$CERTS/ca.pem" \
        -passout "pass:$P12_PASSWORD" -out "$CERTS/server.p12" 2>>"$RIG_LOGS/openssl.log"
    chmod 600 "$CERTS"/*.key "$CERTS/server.p12"
    rm -f "$CERTS/server.csr"
fi

# ------------------------------------------------------------------------------------------ repositories
REPOS="$RIG_DIR/repos"
rig_git() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$GIT" -c user.name=Rig -c user.email=rig@example.invalid "$@"; }
if [[ ! -d "$REPOS/project.git" ]]; then
    info "creating bare repositories"
    rig_git init -q --bare -b main "$REPOS/project.git"
    work="$(mktemp -d "${TMPDIR:-/tmp}/jit-rig-seed.XXXXXX")"
    rig_git init -q -b main "$work"
    printf '# project\n\nServed by the Jit enterprise test rig.\n' >"$work/README.md"
    rig_git -C "$work" add README.md
    GIT_AUTHOR_DATE="2026-01-01T12:00:00Z" GIT_COMMITTER_DATE="2026-01-01T12:00:00Z" \
        rig_git -C "$work" commit -q -m "Initial commit"
    printf 'hello from the rig\n' >"$work/hello.txt"
    rig_git -C "$work" add hello.txt
    GIT_AUTHOR_DATE="2026-01-02T12:00:00Z" GIT_COMMITTER_DATE="2026-01-02T12:00:00Z" \
        rig_git -C "$work" commit -q -m "Add hello.txt"
    rig_git -C "$work" push -q "$REPOS/project.git" main
    rm -rf "$work"
fi

USERS="$RIG_DIR/users.txt"
printf 'ada:rig-token-ada\ngrace:rig-token-grace\n' >"$USERS"
chmod 600 "$USERS"
PROXY_USER="rig-proxy"
PROXY_PASSWORD="rig-proxy-pass"

# ------------------------------------------------------------------------------------------------- ssh
SSH="$RIG_DIR/ssh"
if [[ ! -f "$SSH/ssh_host_ed25519_key" ]]; then
    info "generating SSH host and client keys"
    ssh-keygen -q -t ed25519 -N "" -C "jit-rig-host" -f "$SSH/ssh_host_ed25519_key"
    ssh-keygen -q -t ed25519 -N "" -C "jit-rig-client" -f "$SSH/client_ed25519"
    ssh-keygen -q -t ed25519 -N "rig-passphrase" -C "jit-rig-client-pass" -f "$SSH/client_ed25519_pass"
fi
cat "$SSH/client_ed25519.pub" "$SSH/client_ed25519_pass.pub" >"$SSH/authorized_keys"
chmod 600 "$SSH/authorized_keys" "$SSH/ssh_host_ed25519_key" "$SSH/client_ed25519" "$SSH/client_ed25519_pass"

port_in_use() { nc -z 127.0.0.1 "$1" >/dev/null 2>&1; }
pick_port() { # random high port that nothing listens on
    local port tries=0
    while ((tries < 200)); do
        port=$((20000 + RANDOM % 40000))
        port_in_use "$port" || { echo "$port"; return 0; }
        tries=$((tries + 1))
    done
    die "no free port found"
}

wait_for() { # <seconds> <command...>
    local deadline=$((SECONDS + $1)); shift
    until "$@"; do
        ((SECONDS < deadline)) || return 1
        sleep 0.1
    done
}

SSH_PORT="$(pick_port)"
GIT_EXEC_DIR="$(dirname "$GIT")"
cat >"$SSH/sshd_config" <<EOF
# Generated by scripts/testing/enterprise-rig/up.sh — user-level sshd for the Jit test rig.
ListenAddress 127.0.0.1
Port $SSH_PORT
HostKey $SSH/ssh_host_ed25519_key
PidFile $SSH/sshd.pid
AuthorizedKeysFile $SSH/authorized_keys
AllowUsers $USER
PubkeyAuthentication yes
PasswordAuthentication no
# Tests deliberately fail authentication; no per-source penalties on the loopback rig.
PerSourcePenalties no
MaxStartups 100
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PermitRootLogin no
AllowTcpForwarding no
X11Forwarding no
SetEnv PATH=$GIT_EXEC_DIR:/usr/bin:/bin:/usr/sbin:/sbin
EOF
"$SSHD" -t -f "$SSH/sshd_config" 2>"$RIG_LOGS/sshd-config.log" \
    || { cat "$RIG_LOGS/sshd-config.log" >&2; die "sshd rejected the generated config"; }
info "starting sshd on 127.0.0.1:$SSH_PORT"
"$SSHD" -D -e -f "$SSH/sshd_config" >"$RIG_LOGS/sshd.log" 2>&1 &
echo $! >"$RIG_RUN/sshd.pid"
wait_for 10 port_in_use "$SSH_PORT" || { tail -20 "$RIG_LOGS/sshd.log" >&2; die "sshd did not start"; }

# ------------------------------------------------------------------------------------- TestRig services
# start_rig <name> <TestRig args...>: backgrounds TestRig, waits for its READY lines, records the pid.
start_rig() {
    local name="$1"; shift
    "$TESTRIG" "$@" >"$RIG_LOGS/$name.out" 2>"$RIG_LOGS/$name.err" &
    echo $! >"$RIG_RUN/$name.pid"
    if ! wait_for 15 grep -q '^READY ' "$RIG_LOGS/$name.out"; then
        cat "$RIG_LOGS/$name.err" >&2
        "$(dirname "$0")/down.sh" >/dev/null 2>&1 || true
        die "$name did not become ready"
    fi
}
ready_port() { awk -v role="$2" '$1 == "READY" && $3 == role { print $2; exit }' "$RIG_LOGS/$1.out"; }
wait_ready() { [[ -n "$(ready_port "$1" "$2")" ]]; }

export JIT_RIG_P12_PASSWORD="$P12_PASSWORD"
SSH_BASE="ssh://$USER@127.0.0.1:$SSH_PORT$REPOS"
start_rig https git-server --repos "$REPOS" --p12 "$CERTS/server.p12" --users "$USERS" \
    --ssh-base "$SSH_BASE" --log "$RIG_LOGS/https-requests.log"
start_rig https-prefix git-server --repos "$REPOS" --p12 "$CERTS/server.p12" --users "$USERS" --any-username \
    --deny-user grace --path-prefix /gitlab --ssh-base "$SSH_BASE" --log "$RIG_LOGS/https-prefix-requests.log"
start_rig http git-server --repos "$REPOS" --log "$RIG_LOGS/http-requests.log"
start_rig proxy-auth proxy --socks-port 0 --auth "$PROXY_USER:$PROXY_PASSWORD" --log "$RIG_LOGS/proxy-auth-tunnels.log"
start_rig proxy proxy --socks-port 0 --log "$RIG_LOGS/proxy-tunnels.log"
unset JIT_RIG_P12_PASSWORD
wait_for 5 wait_ready proxy-auth socks5 || die "proxy-auth SOCKS5 listener not ready"
wait_for 5 wait_ready proxy socks5 || die "proxy SOCKS5 listener not ready"

HTTPS_PORT="$(ready_port https https)"
HTTPS_PREFIX_PORT="$(ready_port https-prefix https)"
HTTP_PORT="$(ready_port http http)"
PROXY_AUTH_PORT="$(ready_port proxy-auth http-proxy)"
SOCKS_AUTH_PORT="$(ready_port proxy-auth socks5)"
PROXY_PORT="$(ready_port proxy http-proxy)"
SOCKS_PORT="$(ready_port proxy socks5)"

# ------------------------------------------------------------------------------------------- rig.env/json
vars=(
    JIT_RIG_DIR "$RIG_DIR"
    JIT_RIG_HTTPS_PORT "$HTTPS_PORT"
    JIT_RIG_HTTPS_PREFIX_PORT "$HTTPS_PREFIX_PORT"
    JIT_RIG_HTTPS_PREFIX "/gitlab"
    JIT_RIG_HTTP_PORT "$HTTP_PORT"
    JIT_RIG_PROXY_PORT "$PROXY_PORT"
    JIT_RIG_PROXY_AUTH_PORT "$PROXY_AUTH_PORT"
    JIT_RIG_SOCKS_PORT "$SOCKS_PORT"
    JIT_RIG_SOCKS_AUTH_PORT "$SOCKS_AUTH_PORT"
    JIT_RIG_PROXY_USER "$PROXY_USER"
    JIT_RIG_PROXY_PASSWORD "$PROXY_PASSWORD"
    JIT_RIG_SSH_PORT "$SSH_PORT"
    JIT_RIG_SSH_USER "$USER"
    JIT_RIG_SSH_HOST_KEY_PUB "$SSH/ssh_host_ed25519_key.pub"
    JIT_RIG_CLIENT_KEY "$SSH/client_ed25519"
    JIT_RIG_CLIENT_KEY_PASS "$SSH/client_ed25519_pass"
    JIT_RIG_CLIENT_KEY_PASSPHRASE "rig-passphrase"
    JIT_RIG_CA "$CERTS/ca.pem"
    JIT_RIG_OTHER_CA "$CERTS/other-ca.pem"
    JIT_RIG_LEAF_SELFSIGNED "$CERTS/leaf-selfsigned.pem"
    JIT_RIG_SERVER_CERT "$CERTS/server.pem"
    JIT_RIG_REPOS "$REPOS"
    JIT_RIG_USERS_FILE "$USERS"
    JIT_RIG_USERS "ada:rig-token-ada grace:rig-token-grace"
    JIT_RIG_PREFIX_DENIED_USER "grace"
    JIT_RIG_LOGS "$RIG_LOGS"
)
{
    echo "# Generated by scripts/testing/enterprise-rig/up.sh — throwaway test values only."
    for ((i = 0; i < ${#vars[@]}; i += 2)); do
        printf 'export %s=%q\n' "${vars[i]}" "${vars[i + 1]}"
    done
} >"$RIG_DIR/rig.env"
json_escape() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }
{
    echo "{"
    for ((i = 0; i < ${#vars[@]}; i += 2)); do
        sep=","; ((i + 2 >= ${#vars[@]})) && sep=""
        value="${vars[i + 1]}"
        if [[ "${vars[i]}" == *_PORT && "$value" =~ ^[0-9]+$ ]]; then
            printf '  "%s": %s%s\n' "${vars[i]}" "$value" "$sep"
        else
            printf '  "%s": "%s"%s\n' "${vars[i]}" "$(json_escape "$value")" "$sep"
        fi
    done
    echo "}"
} >"$RIG_DIR/rig.json"

info "rig is up — source $RIG_DIR/rig.env"
cat <<EOF
  https          https://127.0.0.1:$HTTPS_PORT/git/project.git   (api: /api/v4)
  https+prefix   https://127.0.0.1:$HTTPS_PREFIX_PORT/gitlab/git/project.git   (any username; grace denied)
  http           http://127.0.0.1:$HTTP_PORT/git/project.git   (anonymous)
  proxy          http://127.0.0.1:$PROXY_PORT  socks5://127.0.0.1:$SOCKS_PORT
  proxy (auth)   http://127.0.0.1:$PROXY_AUTH_PORT  socks5://127.0.0.1:$SOCKS_AUTH_PORT
  ssh            $SSH_BASE/project.git
EOF
