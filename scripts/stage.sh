#!/usr/bin/env bash
# Single-quoted jq programs and Markdown backticks are literal on purpose.
# shellcheck disable=SC2016
# Renders the npm packages from the per-platform builds.
#
#   scripts/stage.sh <builddir> <outdir>
#
# <builddir>/<platform>/{git/,COPYING} are the outputs of scripts/build.sh, one
# per platform in upstream.json.
# Result: <outdir>/git            the launcher (bin, binaryPath(), env(), upstreamVersion)
#         <outdir>/git-<platform> one package per platform tree
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
manifest=${UPSTREAM_JSON:-$root/upstream.json}
built=${1:?usage: stage.sh <builddir> <outdir>}
out=${2:?usage: stage.sh <builddir> <outdir>}

scope=@ai-swfactory-oss
repo_url=https://github.com/ai-swfactory-oss/git.git
upstream=$(jq -er .version "$manifest")
version=$(bash "$root/scripts/pkgver.sh")
read -r -a platforms <<<"$(jq -r '.platforms | join(" ")' "$manifest")"
release="https://github.com/ai-swfactory-oss/git/releases/tag/v$version"

common='{
  license: "GPL-2.0-only",
  author: "ai-swfactory",
  homepage: "https://github.com/ai-swfactory-oss/git#readme",
  bugs: { url: "https://github.com/ai-swfactory-oss/git/issues" },
  repository: { type: "git", url: $repo },
  publishConfig: { registry: "https://npm.pkg.github.com" }
}'

notice() { # <package name> <tree line>
  cat "$root/packages/NOTICE.in"
  printf '\nThis package: %s %s, built from git %s.\n' "$1" "$version" "$upstream"
  printf '%s\n\n' "$2"
  printf 'Corresponding source (GPL-2.0, section 3): the GitHub release\n  %s\n' "$release"
  printf 'carries git-%s.tar.xz from kernel.org with its signature\n' "$upstream"
  printf 'git-%s.tar.sign, verified against the git maintainer key\n' "$upstream"
  printf '%s pinned in this repository, plus SOURCE-SHA256SUMS and\n' "$(jq -r .signing_key "$manifest")"
  printf 'build-scripts.tar.gz (the scripts, keys, workflows and manifest that built\n'
  printf 'this tree). The same tarball is available from\n'
  printf 'https://www.kernel.org/pub/software/scm/git/.\n'
}

rm -rf "$out"
mkdir -p "$out"

optional='{}'
for platform in "${platforms[@]}"; do
  os=${platform%%-*}
  cpu=${platform#*-}
  name="$scope/git-$platform"
  dir="$out/git-$platform"
  case "$os" in
    linux) linkage="linked dynamically against the host's glibc, zlib (libz.so.1) and libcurl-gnutls.so.4, built on $(jq -r .builder.linux "$manifest" | cut -d' ' -f1) runners; HTTPS needs libcurl-gnutls on the host (Debian and Ubuntu package libcurl3-gnutls or libcurl3t64-gnutls)" ;;
    darwin) linkage="linked against the macOS system libraries only (libcurl, zlib, iconv, CommonCrypto), deployment target $(jq -r .builder.macos_deployment_target "$manifest")" ;;
  esac

  mkdir -p "$dir"
  cp -R "$built/$platform/git" "$dir/git"
  cp "$built/$platform/COPYING" "$dir/LICENSE"
  notice "$name" "Tree: git/ (bin, libexec/git-core, share/git-core/templates), $linkage. No TLS library is included." >"$dir/NOTICE"
  {
    printf '# %s\n\n' "$name"
    printf 'git %s for `%s` / `%s`, built from the signed kernel.org release tarball.\n\n' "$upstream" "$os" "$cpu"
    printf 'Do not install this package directly: install [`%s/git`](https://github.com/ai-swfactory-oss/git), which depends on it optionally and runs it.\n\n' "$scope"
    printf 'The tree is %s.\n\n' "$linkage"
    printf 'Provenance: `gh attestation verify git/bin/git --repo ai-swfactory-oss/git` (run in this package directory).\n\n'
    printf 'License: GPL-2.0-only (see `LICENSE`). The corresponding source is attached to %s (see `NOTICE`).\n' "$release"
  } >"$dir/README.md"

  jq -n --arg name "$name" --arg version "$version" --arg upstream "$upstream" \
    --arg os "$os" --arg cpu "$cpu" --arg repo "$repo_url" \
    "{
      name: \$name,
      version: \$version,
      description: \"git \(\$upstream) for \(\$os)-\(\$cpu) (used by @ai-swfactory-oss/git)\",
      keywords: [\"git\", \"vcs\"],
      os: [\$os],
      cpu: [\$cpu],
      files: [\"git/\", \"LICENSE\", \"NOTICE\", \"README.md\"],
      preferUnplugged: true
    } + $common" >"$dir/package.json"

  optional=$(jq -c --arg n "$name" --arg v "$version" '. + {($n): $v}' <<<"$optional")
done

launcher="$out/git"
mkdir -p "$launcher"
cp -R "$root/packages/git/." "$launcher/"
cp "$built/${platforms[0]}/COPYING" "$launcher/LICENSE"
notice "$scope/git" "This package holds no binary: it runs the tree from $scope/git-<platform>-<arch>." >"$launcher/NOTICE"
jq --arg version "$version" --arg repo "$repo_url" --argjson optional "$optional" \
  ". + {version: \$version, optionalDependencies: \$optional} + $common" \
  "$root/packages/git/package.json" >"$launcher/package.json"
chmod 755 "$launcher/bin/git.js"

echo "stage: $version -> $out"
ls -1 "$out"
