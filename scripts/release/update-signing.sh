#!/usr/bin/env bash
# Sign the exact bytes accepted by Jit's UpdateSigningKey. Use OpenSSL 3 on the signing machine.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage:
  update-signing.sh public-key PRIVATE_KEY_PEM
  update-signing.sh sign VERSION DMG PRIVATE_KEY_PEM
  update-signing.sh verify VERSION DMG PUBLIC_KEY_HEX

`sign` writes DMG.manifest and DMG.manifest.sig alongside the final disk image.
Set JIT_UPDATE_OPENSSL to the path to an OpenSSL 3 executable if needed.
EOF
}

operation="${1:-}"
case "$operation:$#" in
    public-key:2|sign:4|verify:4) ;;
    -h:1|--help:1) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

openssl_bin="${JIT_UPDATE_OPENSSL:-openssl}"
[[ "$("$openssl_bin" version)" == 'OpenSSL 3.'* ]] || die "OpenSSL 3 is required (set JIT_UPDATE_OPENSSL)"
ed25519_prefix=302a300506032b6570032100

if [[ "$operation" == public-key ]]; then
    public_der_hex="$("$openssl_bin" pkey -in "$2" -pubout -outform DER | xxd -p -c 256)"
    [[ "$public_der_hex" =~ ^${ed25519_prefix}[0-9a-f]{64}$ ]] || die "expected an Ed25519 private key"
    printf '%s\n' "${public_der_hex#"$ed25519_prefix"}"
    exit 0
fi

version="$2"
dmg="$3"
[[ "$version" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]] || die "expected MAJOR.MINOR.PATCH"
[[ -f "$dmg" && "${dmg##*/}" == "Jit-$version.dmg" ]] || die "expected the final Jit-$version.dmg"
case "$dmg" in /*) ;; *) dmg="./$dmg" ;; esac
manifest="$dmg.manifest"
signature="$manifest.sig"

work="$(mktemp -d "${TMPDIR:-/tmp}/jit-update-signing.XXXXXX")"
trap 'rm -rf "$work"' EXIT
hash="$(shasum -a 256 "$dmg" | awk '{print $1}')"
printf 'Jit Update Manifest v1\nversion=%s\nsha256=%s\n' "$version" "$hash" > "$work/manifest"

if [[ "$operation" == sign ]]; then
    "$openssl_bin" pkeyutl -sign -rawin -inkey "$4" -in "$work/manifest" -out "$work/signature"
    [[ "$(wc -c < "$work/signature" | tr -d '[:space:]')" == 64 ]] || die "expected a 64-byte Ed25519 signature"
    mv -f "$work/manifest" "$manifest"
    mv -f "$work/signature" "$signature"
else
    [[ "$4" =~ ^[0-9a-f]{64}$ ]] || die "expected a 32-byte lowercase hexadecimal Ed25519 public key"
    [[ -f "$manifest" && -f "$signature" ]] || die "signed manifest assets are missing"
    cmp -s "$work/manifest" "$manifest" || die "manifest does not match this version and disk image"
    [[ "$(wc -c < "$signature" | tr -d '[:space:]')" == 64 ]] || die "expected a 64-byte Ed25519 signature"
    printf '%s%s' "$ed25519_prefix" "$4" | xxd -r -p > "$work/public.der"
    "$openssl_bin" pkeyutl -verify -rawin -pubin -keyform DER -inkey "$work/public.der" \
        -in "$manifest" -sigfile "$signature"
fi
