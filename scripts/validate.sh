#!/usr/bin/env bash
# The repository's validate command (.panoptic.json "validate": "bash scripts/validate.sh"),
# run by `claude-factory work commit` on the gate host. It runs the same path
# the PR CI runs (build.yml), for the gate host's own platform, signature
# checks included:
#
#   1. gpg, gpgv and xz must be on PATH (the tarball is verified with gpgv
#      against a keyring built from the pinned key, no agent involved; without
#      them nothing can be trusted, so validate fails naming them);
#   2. shellcheck over every shell script, and a YAML syntax check of every
#      workflow in .github/workflows with the packaged yamllint
#      (@ai-swfactory-oss/yamllint, installed into a scratch prefix, never
#      globally). A known-bad fixture must fail it first, so the check is not
#      vacuous. A workflow GitHub cannot parse never runs, so the merge would
#      publish nothing;
#   3. named test test/signature-mismatch.sh: a tarball signed by another key,
#      a tampered tarball and a tarball with no signature are each refused;
#      a good signature passes;
#   4. scripts/fetch.sh from kernel.org: the tarball must carry a signature by
#      the key fingerprint pinned in upstream.json, or it is deleted and
#      validate fails;
#   5. scripts/build.sh natively on the gate host (darwin: the system SDK's
#      libcurl, zlib and iconv through /usr/bin/xcrun; nothing is installed),
#      which checks every binary's linkage, --version and --exec-path;
#   6. scripts/stage.sh, then named tests test/launcher.test.js over a launcher
#      staged for all four platforms (the other three trees are stand-ins:
#      the launcher tests never run them);
#   7. stage for the gate host only, npm pack every package once;
#   8. named test scripts/smoke.sh for the gate host's platform: install the
#      packed tarballs into a scratch project, binaryPath(), env(),
#      --version, --exec-path inside the package, init/commit/log, ls-remote
#      over HTTPS, linkage, NOTICE, no install script.
#
# The other three platforms' build and smoke run in CI (pr.yml, build.yml).
# Needs network, gpg, gpgv, gpgconf, xz, bash, jq, tar, gzip, curl, make, a C
# compiler, file, node, npm and shellcheck.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
# The gate reports only the exit status; keep the full output for diagnosis.
mkdir -p build
exec > >(tee build/validate.log) 2>&1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "== gpg, gpgv, xz"
for tool in gpg gpgv xz; do
  command -v "$tool" >/dev/null 2>&1 ||
    { echo "validate: $tool is not on PATH; the kernel.org signature cannot be verified, so nothing is built" >&2; exit 1; }
done
command -v gpg gpgv xz
gpgv --version >"$work/gpgv-version.txt"
sed -n 1p "$work/gpgv-version.txt"

case "$(uname -s)" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *) echo "validate: unsupported gate host OS $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  arm64 | aarch64) cpu=arm64 ;;
  x86_64 | amd64) cpu=x64 ;;
  *) echo "validate: unsupported gate host CPU $(uname -m)" >&2; exit 1 ;;
esac
host="$os-$cpu"
jq -e --arg p "$host" '.platforms | index($p) != null' upstream.json >/dev/null ||
  { echo "validate: no git package is built for the gate host ($host)" >&2; exit 1; }

echo "== shellcheck"
shellcheck scripts/*.sh test/*.sh

echo "== workflow YAML syntax (packaged yamllint)"
yamllint_version=1.38.0
mkdir -p "$work/yamllint"
printf '{"name":"validate-yamllint","version":"1.0.0","private":true}\n' >"$work/yamllint/package.json"
# The scope's registry line comes from this repository's .npmrc; the token,
# if any, stays in the user's own ~/.npmrc.
cp .npmrc "$work/yamllint/.npmrc"
npm install --prefix "$work/yamllint" --no-save --no-audit --no-fund \
  "@ai-swfactory-oss/yamllint@$yamllint_version" >"$work/yamllint-install.log" 2>&1 ||
  { cat "$work/yamllint-install.log"; echo "validate: could not install @ai-swfactory-oss/yamllint@$yamllint_version" >&2; exit 1; }
yamllint="$work/yamllint/node_modules/.bin/yamllint"
[ -x "$yamllint" ] || { echo "validate: $yamllint is missing after install" >&2; exit 1; }
# Syntax only: no style rules, so only a document YAML cannot parse fails.
syntax_only='{rules: {}}'
printf 'jobs:\n  a:\n    steps:\n      - name: bad (linux: colon)\n' >"$work/bad-workflow.yml"
if "$yamllint" -d "$syntax_only" "$work/bad-workflow.yml" >"$work/bad-workflow.txt" 2>&1; then
  cat "$work/bad-workflow.txt"; echo "validate: yamllint accepted a workflow YAML cannot parse" >&2; exit 1
fi
cat "$work/bad-workflow.txt"
"$yamllint" -d "$syntax_only" .github/workflows/*.yml
echo "workflows: YAML syntax OK"

echo "== named test: signature mismatch"
bash test/signature-mismatch.sh

echo "== fetch (kernel.org signature verified against the pinned key)"
bash scripts/fetch.sh "$work/upstream"

echo "== build on the gate host ($host)"
mkdir -p "$work/built"
bash scripts/build.sh "$work/upstream" "$work/built/$host"

echo "== named tests: launcher (staged for every platform)"
mkdir -p "$work/all"
for platform in $(jq -r '.platforms | join(" ")' upstream.json); do
  mkdir -p "$work/all/$platform/git/bin"
  cp "$work/built/$host/COPYING" "$work/all/$platform/"
  cp "$work/built/$host/git/bin/git" "$work/all/$platform/git/bin/"
done
bash scripts/stage.sh "$work/all" "$work/npm-all"
GIT_LAUNCHER_DIR="$work/npm-all/git" node --test test/launcher.test.js

echo "== stage for the gate host and pack"
jq --arg p "$host" '.platforms = [$p]' upstream.json >"$work/host.json"
UPSTREAM_JSON="$work/host.json" bash scripts/stage.sh "$work/built" "$work/npm"
mkdir -p "$work/tgz"
for dir in "$work"/npm/*/; do
  npm pack "$dir" --pack-destination "$work/tgz" >/dev/null
done
ls -l "$work/tgz"

echo "== named test: smoke on the gate host ($host)"
bash scripts/smoke.sh "$work/tgz" "$host"

echo "validate: OK"
