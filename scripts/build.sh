#!/usr/bin/env bash
# Builds git from the verified kernel.org tarball (the output of
# scripts/fetch.sh) on the machine it runs on, installs it as a relocatable
# tree, and checks how every binary in it links.
#
#   scripts/build.sh <fetchdir> <outdir>
#
# TLS: git is GPL-2.0-only, so no TLS library is built in or shipped. HTTPS
# goes through the HOST's libcurl, linked dynamically:
# - darwin: /usr/lib/libcurl.4.dylib (part of macOS), with zlib and iconv from
#   /usr/lib and CommonCrypto from the system frameworks. The SDK comes from
#   the system xcrun with any toolchain override cleared, so a nix shell and a
#   GitHub macOS runner resolve the same Apple SDK; Homebrew is never used
#   (NO_HOMEBREW). The result may load nothing outside /usr/lib and /System.
# - linux: libcurl-gnutls.so.4 (curl built against GnuTLS, LGPL-2.1+; the
#   flavour Debian and Ubuntu link their own git with), libz.so.1 and glibc.
#   Built on ubuntu-22.04 runners (glibc 2.35) with libcurl4-gnutls-dev and
#   zlib1g-dev installed. Every ELF file's NEEDED entries must be on the
#   allowlist below; OpenSSL (libssl, libcrypto, libcurl.so.4) is refused.
#
# Left out: gettext, Tcl/Tk, Perl, Python, Rust and expat (NO_* below), so the
# tree holds only git's own C programs, shell helpers and templates.
# RUNTIME_PREFIX makes git find libexec/git-core and its templates relative to
# its own binary, wherever the package is installed.
#
# Result: <outdir>/git/{bin,libexec,share} (binaries stripped, no symlinks),
#         <outdir>/COPYING (GPL-2.0 text from the tarball)
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
manifest=${UPSTREAM_JSON:-$root/upstream.json}
fetched=$(cd "${1:?usage: build.sh <fetchdir> <outdir>}" && pwd)
mkdir -p "${2:?usage: build.sh <fetchdir> <outdir>}"
out=$(cd "$2" && pwd)

version=$(jq -er .version "$manifest")
work=$(mktemp -d)
xz -dc "$fetched/src/git-$version.tar.xz" | tar -xf - -C "$work"
src="$work/git-$version"
cd "$src"

flags=(
  prefix=/git
  RUNTIME_PREFIX=1
  NO_GETTEXT=1 NO_TCLTK=1 NO_PERL=1 NO_PYTHON=1 NO_RUST=1 NO_EXPAT=1 NO_OPENSSL=1
  SKIP_DASHED_BUILT_INS=YesPlease
)

case "$(uname -s)" in
  Darwin)
    MACOSX_DEPLOYMENT_TARGET=$(jq -er .builder.macos_deployment_target "$manifest")
    export MACOSX_DEPLOYMENT_TARGET
    [ -x /usr/bin/xcrun ] || { echo "build: /usr/bin/xcrun is missing (install the Xcode command line tools)" >&2; exit 1; }
    sdk=$(env -u SDKROOT -u DEVELOPER_DIR /usr/bin/xcrun --sdk macosx --show-sdk-path) ||
      { echo "build: xcrun --sdk macosx --show-sdk-path failed" >&2; exit 1; }
    for lib in libcurl.tbd libz.tbd libiconv.tbd; do
      [ -e "$sdk/usr/lib/$lib" ] || { echo "build: the macOS SDK $sdk has no usr/lib/$lib" >&2; exit 1; }
    done
    include="$work/system-include"
    mkdir -p "$include"
    for header in curl zlib.h zconf.h iconv.h; do
      [ -e "$sdk/usr/include/$header" ] || { echo "build: the macOS SDK $sdk has no usr/include/$header" >&2; exit 1; }
      ln -s "$sdk/usr/include/$header" "$include/$header"
    done
    echo "build: system libcurl, zlib and iconv from $sdk"
    flags+=(
      NO_HOMEBREW=1
      CFLAGS="-O2 -I$include"
      LDFLAGS="-L$sdk/usr/lib"
      CURL_CFLAGS="-I$include"
      CURL_LDFLAGS=-lcurl
    )
    ;;
  Linux)
    command -v curl-config >/dev/null 2>&1 ||
      { echo "build: curl-config is missing (install libcurl4-gnutls-dev)" >&2; exit 1; }
    case "$(curl-config --ssl-backends 2>/dev/null)" in
      *GnuTLS*) ;;
      *) echo "build: curl-config does not describe the GnuTLS libcurl (install libcurl4-gnutls-dev, not the OpenSSL flavour)" >&2; exit 1 ;;
    esac
    flags+=(CFLAGS=-O2)
    ;;
  *) echo "build: unsupported build OS $(uname -s)" >&2; exit 1 ;;
esac

make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)" "${flags[@]}" all
rm -rf "$out/git"
make "${flags[@]}" DESTDIR="$out" install
cp COPYING "$out/COPYING"
tree="$out/git"

# npm drops symlinks from packages: replace any with a copy of its target.
find "$tree" -type l >"$work/symlinks.txt"
while IFS= read -r link; do
  cp -L "$link" "$link.tmp"
  mv -f "$link.tmp" "$link"
done <"$work/symlinks.txt"
# git installs its few dashed built-ins as hardlinks of bin/git; make each a
# plain file, so the package holds no link entries.
find "$tree" -type f -links +1 >"$work/hardlinks.txt"
while IFS= read -r f; do
  cp -p "$f" "$f.tmp"
  mv -f "$f.tmp" "$f"
done <"$work/hardlinks.txt"

# Strip every native binary, and check how each one links. Outputs go to files
# before they are searched: an early-exiting reader in a pipe fails the writer
# under pipefail.
find "$tree" -type f -perm -u+x >"$work/executables.txt"
: >"$work/natives.txt"
while IFS= read -r f; do
  file -b "$f" >"$work/kind.txt"
  if grep -qE 'Mach-O|ELF' "$work/kind.txt"; then
    strip "$f"
    echo "$f" >>"$work/natives.txt"
  fi
done <"$work/executables.txt"
[ -s "$work/natives.txt" ] || { echo "build: no native binaries found in $tree" >&2; exit 1; }

allowed_linux='^(libc\.so\.6|libm\.so\.6|libpthread\.so\.0|libdl\.so\.2|librt\.so\.1|libresolv\.so\.2|libz\.so\.1|libcurl-gnutls\.so\.4|ld-linux-x86-64\.so\.2|ld-linux-aarch64\.so\.1)$'
case "$(uname -s)" in
  Linux)
    while IFS= read -r f; do
      readelf -d "$f" >"$work/dynamic.txt" 2>&1 || true
      sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p' "$work/dynamic.txt" >"$work/needed.txt"
      while IFS= read -r lib; do
        [[ "$lib" =~ $allowed_linux ]] || { cat "$work/dynamic.txt" >&2; echo "build: $f needs $lib, which is not on the allowlist" >&2; exit 1; }
      done <"$work/needed.txt"
    done <"$work/natives.txt"
    readelf -d "$tree/libexec/git-core/git-remote-http" >"$work/remote-http.txt"
    grep -q 'libcurl-gnutls\.so\.4' "$work/remote-http.txt" ||
      { cat "$work/remote-http.txt" >&2; echo "build: git-remote-http does not link libcurl-gnutls.so.4" >&2; exit 1; }
    ;;
  Darwin)
    while IFS= read -r f; do
      otool -L "$f" >"$work/linkage.txt"
      if tail -n +2 "$work/linkage.txt" | grep -vqE '^[[:space:]]+(/usr/lib/|/System/Library/)'; then
        cat "$work/linkage.txt" >&2; echo "build: $f loads a library outside the system" >&2; exit 1
      fi
    done <"$work/natives.txt"
    otool -L "$tree/libexec/git-core/git-remote-http" >"$work/remote-http.txt"
    grep -q '/usr/lib/libcurl\.4\.dylib' "$work/remote-http.txt" ||
      { cat "$work/remote-http.txt" >&2; echo "build: git-remote-http does not load /usr/lib/libcurl.4.dylib" >&2; exit 1; }
    ;;
esac
cat "$work/remote-http.txt"

"$tree/bin/git" --version >"$work/version.txt"
first=$(sed -n 1p "$work/version.txt")
echo "$first"
[ "$first" = "git version $version" ] || { echo "build: git --version does not report $version" >&2; exit 1; }
# Compare real paths: on macOS /var is a symlink to /private/var.
exec_path=$("$tree/bin/git" --exec-path)
expected=$(cd "$tree/libexec/git-core" && pwd -P)
actual=missing
if [ -d "$exec_path" ]; then actual=$(cd "$exec_path" && pwd -P); fi
if [ "$actual" != "$expected" ]; then
  echo "build: git --exec-path is $exec_path, not $expected (RUNTIME_PREFIX)" >&2; exit 1
fi
echo "build: $(wc -l <"$work/natives.txt" | tr -d ' ') native binaries; $(du -sh "$tree" | cut -f1) in $tree"
echo "build: $tree OK"
