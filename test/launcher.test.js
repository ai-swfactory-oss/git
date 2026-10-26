'use strict';

// Named tests over the staged launcher package (GIT_LAUNCHER_DIR, the output of scripts/stage.sh): binaryPath() and
// env() throw a typed error naming the os and cpu when no tree is published for them, and a different one when a tree
// is published but its platform package is not installed.

const assert = require('node:assert/strict');
const path = require('node:path');
const { test } = require('node:test');

const dir = process.env.GIT_LAUNCHER_DIR;
if (dir === undefined) throw new Error('set GIT_LAUNCHER_DIR to the staged launcher package (scripts/stage.sh output)');
const launcher = require(path.resolve(dir, 'index.js'));

for (const fn of ['binaryPath', 'env']) {
  test(`on an unsupported platform, ${fn}() throws UnsupportedPlatformError naming the os and cpu`, () => {
    assert.throws(
      () => launcher[fn]('win32', 'x64'),
      (error) =>
        error instanceof launcher.UnsupportedPlatformError &&
        error.name === 'UnsupportedPlatformError' &&
        error.platform === 'win32' &&
        error.arch === 'x64' &&
        /os win32 and cpu x64/.test(error.message)
    );
  });

  test(`on a supported platform whose package is not installed, ${fn}() throws PlatformPackageMissingError`, () => {
    const [platform, arch] = launcher.supportedPlatforms[0].split('-');
    assert.throws(
      () => launcher[fn](platform, arch),
      (error) =>
        error instanceof launcher.PlatformPackageMissingError &&
        error.packageName === `@ai-swfactory-oss/git-${platform}-${arch}` &&
        error.platform === platform &&
        error.arch === arch
    );
  });
}

test('the launcher names every platform git is built for', () => {
  assert.deepEqual([...launcher.supportedPlatforms].sort(), ['darwin-arm64', 'darwin-x64', 'linux-arm64', 'linux-x64']);
});

test('upstreamVersion is the git version, with no re-pack suffix', () => {
  assert.match(launcher.upstreamVersion, /^\d+\.\d+\.\d+$/);
});
