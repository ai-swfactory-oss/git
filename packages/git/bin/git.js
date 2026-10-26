#!/usr/bin/env node
'use strict';

const { spawnSync } = require('node:child_process');
const { binaryPath, env } = require('../index.js');

let bin;
let gitEnv;
try {
  bin = binaryPath();
  gitEnv = env();
} catch (err) {
  console.error(err.message);
  process.exit(1);
}

const result = spawnSync(bin, process.argv.slice(2), { stdio: 'inherit', env: { ...process.env, ...gitEnv } });
if (result.error) {
  console.error(`@ai-swfactory-oss/git: cannot run ${bin}: ${result.error.message}`);
  process.exit(1);
}
if (result.signal) {
  process.kill(process.pid, result.signal);
}
process.exit(result.status === null ? 1 : result.status);
