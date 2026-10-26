/** The git version this package runs (e.g. 2.56.0), without any -r.N re-pack suffix. */
export declare const upstreamVersion: string;

/** The `<os>-<cpu>` platforms a tree is published for. */
export declare const supportedPlatforms: readonly string[];

/** No git tree is published for this os and cpu. */
export declare class UnsupportedPlatformError extends Error {
  readonly name: 'UnsupportedPlatformError';
  readonly platform: string;
  readonly arch: string;
}

/** A tree is published for this os and cpu, but its platform package is not installed. */
export declare class PlatformPackageMissingError extends Error {
  readonly name: 'PlatformPackageMissingError';
  readonly platform: string;
  readonly arch: string;
  readonly packageName: string;
}

/** Name of the platform package that carries the tree for this os and cpu (default: this process's). */
export declare function platformPackage(platform?: string, arch?: string): string;

/**
 * Absolute path of the git binary for this os and cpu (default: this process's). Throws UnsupportedPlatformError when
 * no tree is published for them, and PlatformPackageMissingError when one is but its package is not installed.
 */
export declare function binaryPath(platform?: string, arch?: string): string;

/** GIT_EXEC_PATH and GIT_TEMPLATE_DIR inside the package, to merge over the child's environment. Throws like binaryPath(). */
export declare function env(platform?: string, arch?: string): { GIT_EXEC_PATH: string; GIT_TEMPLATE_DIR: string };
