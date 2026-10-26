#!/usr/bin/env bash
# Named test: scripts/fetch.sh, which the build runs before it extracts,
# compiles or publishes anything, refuses
#   - a tarball signed by a key other than the pinned fingerprint,
#   - a tarball whose content no longer matches its signature (tampered),
#   - a tarball with no signature file,
# deleting the refused tarball each time, and accepts the same tarball with a
# good signature by the pinned key, so the checks are not vacuous. Like
# kernel.org, the fixture signs the uncompressed .tar and serves the .tar.xz.
# Runs offline: the "mirror" is local files, signed with throwaway keys
# generated here.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)

for tool in gpg gpgconf xz; do
  command -v "$tool" >/dev/null 2>&1 || { echo "signature-mismatch: $tool is not on PATH" >&2; exit 1; }
done

work=$(mktemp -d)
# Generating and signing with the throwaway keys starts a gpg-agent, whose
# socket lives in GNUPGHOME: keep that path short (macOS limits a socket path
# to 104 bytes, and $TMPDIR there is long), and stop the agent on exit.
GNUPGHOME=$(mktemp -d /tmp/gpg.XXXXXX)
export GNUPGHOME
chmod 700 "$GNUPGHOME"
trap 'gpgconf --homedir "$GNUPGHOME" --kill gpg-agent >/dev/null 2>&1 || true; rm -rf "$GNUPGHOME" "$work"' EXIT

# Two throwaway keys: "good" (pinned) and "other" (not pinned).
gpg --batch --quiet --passphrase '' --quick-gen-key 'good <good@example.invalid>' ed25519 sign never
gpg --batch --quiet --passphrase '' --quick-gen-key 'other <other@example.invalid>' ed25519 sign never
good=$(gpg --batch --with-colons --list-keys good@example.invalid | awk -F: '$1 == "fpr" { print $10; exit }')
gpg --batch --armor --export good@example.invalid >"$work/good.asc"

mkdir -p "$work/mirror" "$work/srcdir/git-9.9.9"
make_tarball() { # <readme text>
  printf '%s\n' "$1" >"$work/srcdir/git-9.9.9/README"
  tar -cf "$work/git-9.9.9.tar" -C "$work/srcdir" git-9.9.9
  xz -c "$work/git-9.9.9.tar" >"$work/mirror/git-9.9.9.tar.xz"
}
sign() { # <key>: signs the uncompressed tar, as kernel.org does
  gpg --batch --quiet --yes --local-user "$1@example.invalid" --detach-sign -o "$work/mirror/git-9.9.9.tar.sign" "$work/git-9.9.9.tar"
}

jq -n --arg k "$good" '{version: "9.9.9", repack: 0, signing_key: $k}' >"$work/manifest.json"

run_fetch() { # <case>
  # fetch.sh verifies with gpgv against a keyring built from the key file given
  # here alone, so it trusts nothing in this GNUPGHOME.
  UPSTREAM_JSON="$work/manifest.json" UPSTREAM_BASE_URL="file://$work/mirror" UPSTREAM_KEY_FILE="$work/good.asc" \
    bash "$root/scripts/fetch.sh" "$work/out-$1"
}

expect_refusal() { # <case> <log pattern>
  set +e
  run_fetch "$1" >"$work/$1.log" 2>&1
  local rc=$?
  set -e
  cat "$work/$1.log"
  [ "$rc" -ne 0 ] || { echo "signature-mismatch: $1: fetch accepted it" >&2; exit 1; }
  grep -q "$2" "$work/$1.log" || { echo "signature-mismatch: $1: the failure does not say '$2'" >&2; exit 1; }
  if [ -e "$work/out-$1/src/git-9.9.9.tar.xz" ]; then
    echo "signature-mismatch: $1: the tarball was left behind" >&2; exit 1
  fi
}

make_tarball 'fake'
sign other
expect_refusal wrongkey 'signature check failed for git-9.9.9.tar.xz'

sign good
make_tarball 'tampered after signing'
expect_refusal tampered 'signature check failed for git-9.9.9.tar.xz'

make_tarball 'fake'
rm -f "$work/mirror/git-9.9.9.tar.sign"
expect_refusal nosig 'no signature for git-9.9.9.tar.xz'

sign good
run_fetch good
cmp "$work/mirror/git-9.9.9.tar.xz" "$work/out-good/src/git-9.9.9.tar.xz"
grep -q ' git-9.9.9.tar.xz$' "$work/out-good/src/SOURCE-SHA256SUMS"
grep -q ' git-9.9.9.tar.sign$' "$work/out-good/src/SOURCE-SHA256SUMS"

echo "signature-mismatch: OK"
