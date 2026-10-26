#!/usr/bin/env bash
# Prints the npm package version for upstream.json: <version> (git 2.56.0 is
# 2.56.0), or <version>-r.<repack> when this repository re-packs the same
# upstream source.
set -euo pipefail
manifest=${UPSTREAM_JSON:-$(cd "$(dirname "$0")/.." && pwd)/upstream.json}
jq -er '.version as $v | if (.repack // 0) > 0 then "\($v)-r.\(.repack)" else $v end' "$manifest"
