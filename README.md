# git

[![update](https://github.com/ai-swfactory-oss/git/actions/workflows/update.yml/badge.svg)](https://github.com/ai-swfactory-oss/git/actions/workflows/update.yml)
[![build](https://github.com/ai-swfactory-oss/git/actions/workflows/build.yml/badge.svg)](https://github.com/ai-swfactory-oss/git/actions/workflows/build.yml)

[git](https://git-scm.com/) as npm packages: a **native, relocatable git tree per platform, built here from the signed kernel.org release tarball**, updated and published automatically to GitHub Packages. There is no download at install time and there are no install scripts. kernel.org publishes git as source only, so these trees are our builds; the build is attested and the complete corresponding source is attached to every release.

| Package | What |
|---|---|
| `@ai-swfactory-oss/git` | Thin: the `git` bin, and `binaryPath()` / `env()` / `upstreamVersion` for Node. Depends optionally on the four platform packages, pinned exactly. |
| `@ai-swfactory-oss/git-linux-x64` | `git/` (bin, libexec/git-core, templates), dynamic against the host's glibc, zlib and libcurl-gnutls |
| `@ai-swfactory-oss/git-linux-arm64` | the same for arm64 |
| `@ai-swfactory-oss/git-darwin-x64` | `git/`, linked against the macOS system libraries only |
| `@ai-swfactory-oss/git-darwin-arm64` | the same for arm64 |

## Install

GitHub Packages needs the scope line in your project's `.npmrc` (`@ai-swfactory-oss:registry=https://npm.pkg.github.com`) and a `read:packages` token in your user `~/.npmrc`, even for public packages; see the [shfmt wrapper](https://github.com/ai-swfactory-oss/shfmt#install) for details. Then:

```sh
npm install --save-dev @ai-swfactory-oss/git
npx git --version
```

From Node, spawn the binary with `env()` merged into the child's environment:

```js
const { spawnSync } = require('node:child_process');
const { binaryPath, env } = require('@ai-swfactory-oss/git');

spawnSync(binaryPath(), ['status'], { stdio: 'inherit', env: { ...process.env, ...env() } });
```

`env()` returns `GIT_EXEC_PATH` and `GIT_TEMPLATE_DIR` inside the package. git finds both by itself (it is built with `RUNTIME_PREFIX`), but setting them stops a `GIT_EXEC_PATH` inherited from the caller from pointing it at another git's helpers. `binaryPath()` and `env()` throw `UnsupportedPlatformError` or `PlatformPackageMissingError` as in the other wrappers. `upstreamVersion` is the git version, for example `2.56.0`.

## TLS linkage

git is GPL-2.0-only, so this repository ships **no TLS library**: no OpenSSL (whose Apache-2.0 licence is not GPLv2-compatible), and nothing else. HTTPS remotes go through the host's own libcurl, loaded dynamically at run time:

- **macOS:** `/usr/lib/libcurl.4.dylib`, part of the operating system, with zlib and iconv from `/usr/lib` and CommonCrypto from the system frameworks. Nothing outside `/usr/lib` and `/System/Library` is loaded; Homebrew is never used in the build.
- **linux:** `libcurl-gnutls.so.4`, curl built against GnuTLS (LGPL-2.1-or-later), the same flavour Debian and Ubuntu link their own git with, plus `libz.so.1` and glibc. The trees are built on ubuntu-22.04 runners (glibc 2.35). **The host needs `libcurl3-gnutls`** (`libcurl3t64-gnutls` on Ubuntu 24.04 and later; any host with Debian's or Ubuntu's own git has it). Without it, local git works but `git-remote-https` fails to load.

CA certificates come from the host too: the system keychain on macOS, and the CA bundle the host's libcurl-gnutls was configured with on linux.

## How the tree is made, and how to check it

1. **Source.** `upstream.json` names the git version. `scripts/fetch.sh` downloads `git-<version>.tar.xz` and `git-<version>.tar.sign` from kernel.org. kernel.org signs the uncompressed tarball, so the `.tar.xz` is decompressed into `gpgv`, which checks the signature against a keyring built from the key in `keys/` alone. The signature must be by Junio C Hamano's key, fingerprint `96E07AF25771955980DAD10020D04E5A713660A7`, pinned in `upstream.json`; neither the key nor the fingerprint is fetched at run time. A missing, bad or foreign signature deletes the tarball and stops the build before anything is extracted. The named test `test/signature-mismatch.sh` proves each refusal.
2. **Build** (`scripts/build.sh`): `make` with `RUNTIME_PREFIX` (relocatable), `NO_OPENSSL`, `NO_GETTEXT`, `NO_TCLTK`, `NO_PERL`, `NO_PYTHON`, `NO_RUST`, `NO_EXPAT` and `SKIP_DASHED_BUILT_INS`, then `make install` into a tree. Every native binary is stripped, and its linkage is checked: on linux every `NEEDED` entry must be on an allowlist (glibc, zlib, libcurl-gnutls), and on macOS every library must be under `/usr/lib` or `/System/Library`. `git --version` and `git --exec-path` are checked too.
3. **Provenance.** Every published tarball and `git` binary carries a GitHub build-provenance attestation. Check one with `gh attestation verify node_modules/@ai-swfactory-oss/git-linux-x64/git/bin/git --repo ai-swfactory-oss/git`.

## Corresponding source (GPL-2.0)

Every GitHub release `v<version>` carries:
- `git-<version>.tar.xz` from kernel.org, its `.tar.sign`, and `SOURCE-SHA256SUMS`;
- `build-scripts.tar.gz`: the manifest, keys, scripts and workflows that built the trees.

That is the complete corresponding source, together with the scripts that control compilation and installation (GPLv2 section 3). Each package's `NOTICE` names the release and the pinned signing key.

**Releases are never deleted while their package version is served.** No workflow here deletes releases.

## Versions

- The package version is the git version: git 2.56.0 is `2.56.0`.
- A re-pack (a build fix with the same source) is `<that>-r.<n>`, set with `"repack": <n>`. It is published with the dist-tag `latest`.

## Workflows

| Workflow | When | What |
|---|---|---|
| `update` | Daily; monthly keepalive | A newer stable git release on kernel.org becomes a pull request raising `version`, which `build` tests (signature-verified fetch included). A release signed by another key fails the build for a maintainer to review. A missing release for main's version re-runs the publish. |
| `build` | Push to `main` touching the build inputs; manual; called by `update` | Named signature test; signature-verified fetch; build on four runners; stage; launcher tests; pack once; smoke-test the packed tarballs on four runners. On push or manual publish it attests, publishes (platforms first) and creates the release with the source. |
| `pr` | Every pull request | `build` without publishing. |
| `failures` | After `update`/`build` on `main` | Keeps one `build-failure` issue in sync. |

## License

- The scripts and workflows in this repository are **MIT** (see [`LICENSE`](LICENSE)).
- The **npm packages are GPL-2.0-only**, the licence of git. Each package ships git's `COPYING` as `LICENSE`, and a `NOTICE`.

This project is not affiliated with the git project or Software Freedom Conservancy. "Git" is a trademark of Software Freedom Conservancy, used here only to name the software these packages contain.
