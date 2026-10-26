# @ai-swfactory-oss/git

[git](https://git-scm.com/), built from the signed kernel.org release tarball, as an npm package that runs a native, relocatable git tree for your platform. There is no download at install time and there are no install scripts.

Platforms: `darwin-x64` and `darwin-arm64` (macOS system libraries only), and `linux-x64` and `linux-arm64` (dynamic against the host's glibc, zlib and libcurl-gnutls). The tree comes from the matching optional dependency `@ai-swfactory-oss/git-<platform>-<arch>`.

## Install

The package is on GitHub Packages. Put `@ai-swfactory-oss:registry=https://npm.pkg.github.com` in your project's `.npmrc`, and a `read:packages` token in your user `~/.npmrc`. Then:

```sh
npm install --save-dev @ai-swfactory-oss/git
npx git --version
```

## Use

```js
const { spawnSync } = require('node:child_process');
const { binaryPath, env, upstreamVersion } = require('@ai-swfactory-oss/git');

spawnSync(binaryPath(), ['status'], { stdio: 'inherit', env: { ...process.env, ...env() } });
```

`env()` gives `GIT_EXEC_PATH` and `GIT_TEMPLATE_DIR` inside the package. `binaryPath()` and `env()` throw `UnsupportedPlatformError` when no tree is published for this os and cpu, and `PlatformPackageMissingError` when one is published but its package was not installed.

## TLS

No TLS library is included. HTTPS remotes go through the host's libcurl: `/usr/lib/libcurl.4.dylib` on macOS, and `libcurl-gnutls.so.4` on linux (Debian and Ubuntu: `libcurl3-gnutls`, or `libcurl3t64-gnutls` on 24.04 and later). Without it on linux, local git works but `git-remote-https` fails to load.

## Source and licence

GPL-2.0-only. The complete corresponding source is attached to the GitHub release of each version: the kernel.org tarball, its signature, and the build scripts. Each platform package's `NOTICE` names the release and the pinned signing key. Details: https://github.com/ai-swfactory-oss/git#corresponding-source-gpl-20
