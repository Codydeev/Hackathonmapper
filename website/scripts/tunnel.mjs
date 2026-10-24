#!/usr/bin/env node
// Exposes the backend's gateway-only listener (127.0.0.1:3001 by default) through a Cloudflare
// quick tunnel, so a gateway phone on any network can upload. The dashboard stays LAN-only.
// Requires `cloudflared` (Windows: winget install --id Cloudflare.cloudflared).
// Usage: npm run tunnel            (with `npm start` / `npm run watch` already running)

import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const port = Number(process.env.GATEWAY_PORT ?? 3001);
const tokenFile = fileURLToPath(new URL('../.gateway-token', import.meta.url));

function readToken() {
  if (process.env.GATEWAY_TOKEN?.trim()) return process.env.GATEWAY_TOKEN.trim();
  try {
    return readFileSync(tokenFile, 'utf8').trim();
  } catch {
    return null;
  }
}

const token = readToken();
if (!token) {
  console.error('No gateway token yet. Start the backend first (npm start or npm run watch); it creates .gateway-token.');
  process.exit(1);
}

try {
  const health = await fetch(`http://127.0.0.1:${port}/api/health`, { headers: { authorization: `Bearer ${token}` } });
  if (!health.ok) throw new Error(`HTTP ${health.status}`);
} catch (error) {
  console.error(`Gateway listener on 127.0.0.1:${port} is not answering (${error.message}). Is the backend running?`);
  process.exit(1);
}

const child = spawn('cloudflared', ['tunnel', '--no-autoupdate', '--url', `http://127.0.0.1:${port}`], {
  stdio: ['ignore', 'pipe', 'pipe'],
});

child.on('error', (error) => {
  if (error.code === 'ENOENT') {
    console.error('cloudflared was not found on PATH.');
    console.error('Install it: winget install --id Cloudflare.cloudflared   (macOS: brew install cloudflared)');
  } else {
    console.error('Could not start cloudflared:', error.message);
  }
  process.exit(1);
});

let announced = false;
const onOutput = (chunk) => {
  const text = chunk.toString();
  if (process.env.TUNNEL_VERBOSE) process.stderr.write(text);
  const match = text.match(/https:\/\/[a-z0-9-]+\.trycloudflare\.com/);
  if (match && !announced) {
    announced = true;
    void announce(match[0]);
  }
};
child.stdout.on('data', onOutput);
child.stderr.on('data', onOutput);

async function announce(url) {
  console.log('\nCloudflare tunnel is up. In the iPhone app\'s Gateway screen enter:');
  console.log(`  Dashboard URL:  ${url}`);
  console.log(`  Gateway token:  ${token}`);
  console.log('\nOnly /api/health and /api/updates are reachable, and only with the token.');
  console.log('The URL changes every time this script starts. Press Ctrl+C to close the tunnel.\n');

  // The new hostname can take a few seconds to resolve; confirm the round trip once.
  for (let attempt = 0; attempt < 15; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 2000));
    try {
      const response = await fetch(`${url}/api/health`, { headers: { authorization: `Bearer ${token}` } });
      if (response.ok) {
        console.log('Verified: the gateway endpoint answers through the tunnel.');
        return;
      }
    } catch {
      // Not reachable yet.
    }
  }
  console.log('Could not verify the tunnel yet; it may still be propagating. Set TUNNEL_VERBOSE=1 for cloudflared logs.');
}

child.on('exit', (code) => {
  console.log(`cloudflared exited${code === null ? '' : ` with code ${code}`}.`);
  process.exit(code ?? 0);
});

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => child.kill(signal));
}
