#!/usr/bin/env bash
# Downloads the git release tarball named by upstream.json from kernel.org,
# with its detached GPG signature, and verifies the signature against the git
# maintainer key pinned in this repository: the fingerprint in upstream.json
# .signing_key (Junio C Hamano), the public key in keys/. Nothing is fetched to
# decide what to trust: the key comes from the tree, and a signature counts
# only when gpgv reports VALIDSIG by exactly that fingerprint. Verification
# uses gpgv against a keyring built from the pinned key file alone
# (gpg --dearmor), so it needs no gpg-agent and no socket.
#
# kernel.org signs the uncompressed tarball: git-<v>.tar.sign is a signature
# over git-<v>.tar, so the .tar.xz is decompressed into gpgv's standard input.
# A tarball whose signature is missing, bad, or by any other key is deleted and
# the script exits 1, so nothing unverified is extracted, compiled or
# published.
#
#   scripts/fetch.sh <outdir>
#
# UPSTREAM_JSON overrides the manifest; UPSTREAM_BASE_URL overrides the
# kernel.org directory (default https://www.kernel.org/pub/software/scm/git);
# UPSTREAM_KEY_FILE overrides the key file (the tests sign their own fixture
# with a throwaway key).
#
# Result: <outdir>/src/git-<v>.tar.xz, <outdir>/src/git-<v>.tar.sign, and
#         <outdir>/src/SOURCE-SHA256SUMS over both (recorded for the release,
#         not trusted).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
manifest=${UPSTREAM_JSON:-$root/upstream.json}
out=${1:?usage: fetch.sh <outdir>}
base=${UPSTREAM_BASE_URL:-https://www.kernel.org/pub/software/scm/git}
key_file=${UPSTREAM_KEY_FILE:-$root/keys/junio-c-hamano.asc}
fingerprint=$(jq -er .signing_key "$manifest")
version=$(jq -er .version "$manifest")

[[ "$fingerprint" =~ ^[0-9A-F]{40}$ ]] || { echo "fetch: signing key '$fingerprint' is not a 40-hex fingerprint" >&2; exit 1; }
for tool in gpg gpgv xz; do
  command -v "$tool" >/dev/null 2>&1 || { echo "fetch: $tool is not on PATH; the source must be signature-verified" >&2; exit 1; }
done

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# The keyring holds only the pinned key file's packets; gpg --dearmor and gpgv
# start no agent.
keys=$(mktemp -d)
trap 'rm -rf "$keys"' EXIT
keyring="$keys/pinned.gpg"
gpg --batch --homedir "$keys" --dearmor --output "$keyring" "$key_file"

mkdir -p "$out/src"
name="git-$version.tar.xz"
sig="git-$version.tar.sign"
file="$out/src/$name"
echo "fetch: <- $base/$name"
curl -fsSL --retry 3 --retry-delay 5 -o "$file" "$base/$name"
if ! curl -fsSL --retry 3 --retry-delay 5 -o "$out/src/$sig" "$base/$sig"; then
  echo "fetch: no signature for $name ($base/$sig)" >&2
  rm -f "$file" "$out/src/$sig"
  exit 1
fi

status=$( (xz -dc "$file" | gpgv --homedir "$keys" --status-fd 1 --keyring "$keyring" "$out/src/$sig" -) 2>/dev/null || true)
if ! grep -q "^\[GNUPG:\] VALIDSIG .*$fingerprint" <<<"$status"; then
  echo "fetch: signature check failed for $name (expected a valid signature by $fingerprint)" >&2
  printf '%s\n' "$status" | grep '^\[GNUPG:\]' >&2 || true
  rm -f "$file" "$out/src/$sig"
  exit 1
fi

{
  printf '%s  %s\n' "$(sha256 "$file")" "$name"
  printf '%s  %s\n' "$(sha256 "$out/src/$sig")" "$sig"
} >"$out/src/SOURCE-SHA256SUMS"
echo "fetch: $name signed by $fingerprint"
cat "$out/src/SOURCE-SHA256SUMS"
