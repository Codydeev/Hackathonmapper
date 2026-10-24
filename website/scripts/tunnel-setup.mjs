#!/usr/bin/env node
// One-time setup of a named Cloudflare tunnel, so the dashboard keeps a fixed address on your
// domain instead of a random trycloudflare.com URL. The domain must already be on Cloudflare.
// Usage: npm run tunnel:setup -- mesh.example.com [--name meshmapper]
// Afterwards `npm run tunnel` uses this tunnel. Delete .tunnel.json to go back to quick tunnels.

import { spawnSync } from 'node:child_process';
import { existsSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const args = process.argv.slice(2);
const nameIndex = args.indexOf('--name');
const name = nameIndex >= 0 ? args[nameIndex + 1] : 'meshmapper';
const hostname = args.find((arg, index) => !arg.startsWith('--') && index !== nameIndex + 1);

if (!hostname || !/^[a-z0-9-]+(\.[a-z0-9-]+)+$/i.test(hostname) || !/^[A-Za-z0-9_-]+$/.test(name ?? '')) {
  console.error('Usage: npm run tunnel:setup -- <hostname on your Cloudflare domain> [--name meshmapper]');
  console.error('Example: npm run tunnel:setup -- mesh.example.com');
  process.exit(1);
}

function cloudflared(commandArgs, { capture = false } = {}) {
  const result = spawnSync('cloudflared', commandArgs, {
    stdio: capture ? ['ignore', 'pipe', 'inherit'] : 'inherit',
    encoding: 'utf8',
  });
  if (result.error?.code === 'ENOENT') {
    console.error('cloudflared was not found. Install it: winget install --id Cloudflare.cloudflared');
    process.exit(1);
  }
  return result;
}

// 1. Account login (opens a browser once; pick the domain to authorize).
if (!existsSync(join(homedir(), '.cloudflared', 'cert.pem'))) {
  console.log('Opening the Cloudflare login in your browser. Choose the domain for the dashboard.');
  if (cloudflared(['tunnel', 'login']).status !== 0) process.exit(1);
}

// 2. Create the tunnel unless it already exists.
const list = cloudflared(['tunnel', 'list', '--output', 'json'], { capture: true });
const existing = list.status === 0 ? JSON.parse(list.stdout || '[]').find((tunnel) => tunnel.name === name) : null;
if (existing) {
  console.log(`Using existing tunnel "${name}" (${existing.id}).`);
} else if (cloudflared(['tunnel', 'create', name]).status !== 0) {
  process.exit(1);
}

// 3. Point the hostname at the tunnel (replaces an existing DNS record for it).
if (cloudflared(['tunnel', 'route', 'dns', '--overwrite-dns', name, hostname]).status !== 0) process.exit(1);

writeFileSync(
  fileURLToPath(new URL('../.tunnel.json', import.meta.url)),
  `${JSON.stringify({ name, hostname }, null, 2)}\n`,
);
console.log(`\nDone. \`npm run tunnel\` now publishes the dashboard at https://${hostname}`);
