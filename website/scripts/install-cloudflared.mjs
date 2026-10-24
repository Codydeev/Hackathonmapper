#!/usr/bin/env node
// Downloads the official cloudflared release binary from Cloudflare's GitHub releases into
// website/.bin/ (git-ignored), for machines without winget, Scoop, Chocolatey or admin rights.
// Usage: npm run tunnel:install

import { spawnSync } from 'node:child_process';
import { chmodSync, mkdirSync, renameSync, writeFileSync } from 'node:fs';
import { LOCAL_BIN_DIR, LOCAL_BINARY } from './cloudflared.mjs';

const RELEASES = 'https://github.com/cloudflare/cloudflared/releases/latest/download';
const assets = {
  'win32-x64': 'cloudflared-windows-amd64.exe',
  'win32-arm64': 'cloudflared-windows-amd64.exe', // runs under Windows on Arm x64 emulation
  'win32-ia32': 'cloudflared-windows-386.exe',
  'linux-x64': 'cloudflared-linux-amd64',
  'linux-arm64': 'cloudflared-linux-arm64',
  'linux-arm': 'cloudflared-linux-arm',
};

const asset = assets[`${process.platform}-${process.arch}`];
if (!asset) {
  console.error(`No direct download for ${process.platform}/${process.arch}.`);
  console.error(process.platform === 'darwin' ? 'On macOS use: brew install cloudflared' : 'See https://github.com/cloudflare/cloudflared/releases/latest');
  process.exit(1);
}

const url = `${RELEASES}/${asset}`;
console.log(`Downloading ${url}`);
const response = await fetch(url);
if (!response.ok) {
  console.error(`Download failed: HTTP ${response.status}`);
  process.exit(1);
}

mkdirSync(LOCAL_BIN_DIR, { recursive: true });
const partial = `${LOCAL_BINARY}.download`;
writeFileSync(partial, Buffer.from(await response.arrayBuffer()));
if (process.platform !== 'win32') chmodSync(partial, 0o755);
renameSync(partial, LOCAL_BINARY);

const version = spawnSync(LOCAL_BINARY, ['--version'], { encoding: 'utf8' });
if (version.status !== 0) {
  console.error('Downloaded, but the binary did not run:', version.error?.message ?? version.stderr);
  process.exit(1);
}
console.log(`Installed ${version.stdout.trim()} to ${LOCAL_BINARY}`);
console.log('`npm run tunnel` and `npm run tunnel:setup` will use it automatically.');
