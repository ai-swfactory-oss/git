#!/usr/bin/env bash
# The single-quoted node programs are literal on purpose.
# shellcheck disable=SC2016
# Named test, per platform: installs the packed tarballs into a scratch project,
# as a consumer would, and checks that binaryPath() resolves to an executable
# git that reports upstreamVersion and whose --exec-path is inside the package;
# that init, commit and log work in a scratch HOME with no system or global
# config; that git ls-remote over HTTPS works (the host libcurl path); and that
# every native binary links the way the build promises (linux: only the host
# glibc, zlib and libcurl-gnutls, all resolvable; darwin: system libraries
# only). It also checks each tarball's NOTICE and that none declares an
# install script.
#
#   scripts/smoke.sh <tgzdir> <platform>      e.g. dist/tgz linux-x64
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tgz=$(cd "${1:?usage: smoke.sh <tgzdir> <platform>}" && pwd)
platform=${2:?usage: smoke.sh <tgzdir> <platform>}
upstream=$(jq -er .version "$root/upstream.json")
version=$(bash "$root/scripts/pkgver.sh")

launcher="$tgz/ai-swfactory-oss-git-$version.tgz"
native="$tgz/ai-swfactory-oss-git-$platform-$version.tgz"

# Read tarball contents into files first: `tar ... | grep -q` under pipefail
# fails when grep exits early and tar hits the closed pipe.
scan=$(mktemp -d)
for f in "$launcher" "$native"; do
  test -f "$f" || { echo "smoke: missing $f" >&2; exit 1; }
  tar -xzOf "$f" package/package.json >"$scan/package.json"
  if jq -e '.scripts // {} | keys | any(test("install"))' "$scan/package.json" >/dev/null; then
    echo "smoke: $f declares an install script" >&2; exit 1
  fi
  tar -xzOf "$f" package/NOTICE >"$scan/NOTICE"
  grep -q 'Corresponding source' "$scan/NOTICE" || { echo "smoke: $f NOTICE does not point at the corresponding source" >&2; exit 1; }
  grep -qi 'no TLS library is included' "$scan/NOTICE" || { echo "smoke: $f NOTICE does not state the TLS linkage" >&2; exit 1; }
done

work=$(mktemp -d)
cd "$work" || exit 1
printf '{"name":"smoke","version":"1.0.0","private":true}\n' >package.json
npm install --no-audit --no-fund "$launcher" "$native"

echo "== binaryPath(), env(), upstreamVersion, --version and --exec-path"
node -e '
  const { execFileSync } = require("node:child_process");
  const fs = require("node:fs");
  const path = require("node:path");
  const git = require("@ai-swfactory-oss/git");
  const [expected] = process.argv.slice(1);
  if (git.upstreamVersion !== expected) throw new Error(`upstreamVersion ${git.upstreamVersion} != ${expected}`);
  const bin = git.binaryPath();
  fs.accessSync(bin, fs.constants.X_OK);
  const env = { ...process.env, ...git.env() };
  const printed = execFileSync(bin, ["--version"], { encoding: "utf8", env }).trim();
  if (printed !== `git version ${expected}`) throw new Error(`${bin} reports ${printed}`);
  const pkgDir = fs.realpathSync(path.dirname(require.resolve(`${git.platformPackage()}/package.json`)));
  const execPath = fs.realpathSync(execFileSync(bin, ["--exec-path"], { encoding: "utf8", env }).trim());
  if (!execPath.startsWith(pkgDir + path.sep)) throw new Error(`--exec-path ${execPath} is outside ${pkgDir}`);
  // Built relocatable: without env() too, git finds its own helpers.
  const bare = { ...process.env };
  delete bare.GIT_EXEC_PATH;
  const own = fs.realpathSync(execFileSync(bin, ["--exec-path"], { encoding: "utf8", env: bare }).trim());
  if (own !== execPath) throw new Error(`without env(), --exec-path is ${own}, not ${execPath}`);
  console.log(bin, printed, execPath);
' "$upstream"

bin=$(node -p 'require("@ai-swfactory-oss/git").binaryPath()')
exec_dir=$(node -p 'require("@ai-swfactory-oss/git").env().GIT_EXEC_PATH')
template_dir=$(node -p 'require("@ai-swfactory-oss/git").env().GIT_TEMPLATE_DIR')

echo "== init, commit, log in a scratch HOME"
export HOME="$work/home" GIT_CONFIG_NOSYSTEM=1 GIT_EXEC_PATH="$exec_dir" GIT_TEMPLATE_DIR="$template_dir"
mkdir -p "$HOME" "$work/repo"
"$bin" -C "$work/repo" init -q -b main
test -d "$work/repo/.git/hooks" || { echo "smoke: init did not apply the templates" >&2; exit 1; }
printf 'hello\n' >"$work/repo/hello.txt"
"$bin" -C "$work/repo" add hello.txt
"$bin" -C "$work/repo" -c user.name=smoke -c user.email=smoke@example.invalid commit -q -m 'smoke commit'
"$bin" -C "$work/repo" log --format=%s >"$work/log.txt"
[ "$(cat "$work/log.txt")" = "smoke commit" ] || { cat "$work/log.txt"; echo "smoke: log does not show the commit" >&2; exit 1; }
cat "$work/log.txt"

echo "== ls-remote over HTTPS (host libcurl)"
"$bin" ls-remote https://github.com/git/git HEAD >"$work/ls-remote.txt"
cat "$work/ls-remote.txt"
grep -qE '^[0-9a-f]{40}[[:space:]]+HEAD$' "$work/ls-remote.txt" || { echo "smoke: ls-remote printed no HEAD" >&2; exit 1; }

echo "== linkage"
find "$(dirname "$(dirname "$bin")")" -type f -perm -u+x >"$work/executables.txt"
: >"$work/natives.txt"
while IFS= read -r f; do
  file -b "$f" >"$work/kind.txt"
  if grep -qE 'Mach-O|ELF' "$work/kind.txt"; then echo "$f" >>"$work/natives.txt"; fi
done <"$work/executables.txt"
echo "$(wc -l <"$work/natives.txt" | tr -d ' ') native binaries"
case "$platform" in
  linux-*)
    allowed='^(libc\.so\.6|libm\.so\.6|libpthread\.so\.0|libdl\.so\.2|librt\.so\.1|libresolv\.so\.2|libz\.so\.1|libcurl-gnutls\.so\.4|ld-linux-x86-64\.so\.2|ld-linux-aarch64\.so\.1)$'
    while IFS= read -r f; do
      readelf -d "$f" >"$work/dynamic.txt" 2>&1 || true
      sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p' "$work/dynamic.txt" >"$work/needed.txt"
      while IFS= read -r lib; do
        [[ "$lib" =~ $allowed ]] || { echo "smoke: $f needs $lib, which is not on the allowlist" >&2; exit 1; }
      done <"$work/needed.txt"
      ldd "$f" >"$work/ldd.txt" 2>&1 || true
      if grep -q 'not found' "$work/ldd.txt"; then
        cat "$work/ldd.txt"; echo "smoke: $f has a library the host cannot resolve" >&2; exit 1
      fi
    done <"$work/natives.txt"
    ldd "$exec_dir/git-remote-http" >"$work/ldd.txt"
    cat "$work/ldd.txt"
    ;;
  darwin-*)
    while IFS= read -r f; do
      otool -L "$f" >"$work/otool.txt"
      if tail -n +2 "$work/otool.txt" | grep -vqE '^[[:space:]]+(/usr/lib/|/System/Library/)'; then
        cat "$work/otool.txt"; echo "smoke: $f loads a library outside the system" >&2; exit 1
      fi
    done <"$work/natives.txt"
    otool -L "$exec_dir/git-remote-http" >"$work/otool.txt"
    cat "$work/otool.txt"
    ;;
esac

echo "smoke: $platform OK"
