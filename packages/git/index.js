'use strict';

const path = require('node:path');

const pkg = require('./package.json');

const SCOPE = '@ai-swfactory-oss';
const PREFIX = `${SCOPE}/git-`;

/** The git version this package runs (e.g. 2.56.0), without any -r.N re-pack suffix. */
const upstreamVersion = pkg.version.replace(/-r\.\d+$/, '');

/** The `<os>-<cpu>` platforms a tree is published for, from the exactly pinned optional dependencies. */
const supportedPlatforms = Object.freeze(
  Object.keys(pkg.optionalDependencies || {})
    .filter((name) => name.startsWith(PREFIX))
    .map((name) => name.slice(PREFIX.length))
);

/** No git tree is published for this os and cpu. */
class UnsupportedPlatformError extends Error {
  constructor(platform, arch) {
    super(
      `@ai-swfactory-oss/git: no git is published for os ${platform} and cpu ${arch}; ` +
        `supported: ${supportedPlatforms.join(', ')}`
    );
    this.name = 'UnsupportedPlatformError';
    this.platform = platform;
    this.arch = arch;
  }
}

/** A tree is published for this os and cpu, but its platform package is not installed. */
class PlatformPackageMissingError extends Error {
  constructor(platform, arch, packageName) {
    super(
      `@ai-swfactory-oss/git: ${packageName} is not installed for os ${platform} and cpu ${arch}; ` +
        'reinstall without --omit=optional / --no-optional, or from a lockfile made on this platform'
    );
    this.name = 'PlatformPackageMissingError';
    this.platform = platform;
    this.arch = arch;
    this.packageName = packageName;
  }
}

/** Name of the platform package that carries the tree for this os and cpu. */
function platformPackage(platform = process.platform, arch = process.arch) {
  return `${PREFIX}${platform}-${arch}`;
}

/** Absolute path of the installed git tree (bin, libexec/git-core, share/git-core/templates). */
function treePath(platform = process.platform, arch = process.arch) {
  if (!supportedPlatforms.includes(`${platform}-${arch}`)) throw new UnsupportedPlatformError(platform, arch);
  const name = platformPackage(platform, arch);
  let dir;
  try {
    dir = path.dirname(require.resolve(`${name}/package.json`));
  } catch {
    throw new PlatformPackageMissingError(platform, arch, name);
  }
  return path.join(dir, 'git');
}

/**
 * Absolute path of the git binary for this os and cpu. Throws UnsupportedPlatformError when no tree is published for
 * them, and PlatformPackageMissingError when one is but its package is not installed.
 */
function binaryPath(platform = process.platform, arch = process.arch) {
  return path.join(treePath(platform, arch), 'bin', 'git');
}

/**
 * Environment for spawning binaryPath(): GIT_EXEC_PATH and GIT_TEMPLATE_DIR pointing inside the package. git finds
 * both on its own (it is built relocatable), but setting them keeps a GIT_EXEC_PATH inherited from the caller's
 * environment from pointing it at another git's helpers. Merge it over the child's environment.
 */
function env(platform = process.platform, arch = process.arch) {
  const tree = treePath(platform, arch);
  return {
    GIT_EXEC_PATH: path.join(tree, 'libexec', 'git-core'),
    GIT_TEMPLATE_DIR: path.join(tree, 'share', 'git-core', 'templates'),
  };
}

module.exports = {
  binaryPath,
  env,
  platformPackage,
  PlatformPackageMissingError,
  supportedPlatforms,
  UnsupportedPlatformError,
  upstreamVersion,
};
