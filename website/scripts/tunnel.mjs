#!/usr/bin/env node
// Publishes the dashboard through Cloudflare. The tunnel points at the backend's public listener
// (127.0.0.1:3001), which requires the dashboard key for browsers and the gateway token for phones.
// - With .tunnel.json (from `npm run tunnel:setup -- <hostname>`): a named tunnel on your domain.
// - Without it: a quick tunnel on a random https://….trycloudflare.com URL (no account needed).
// Requires `cloudflared` (see scripts/cloudflared.mjs; `npm run tunnel:install` fetches it) and a
// running backend.

import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import QRCode from 'qrcode';
import { INSTALL_HELP, cloudflaredCommand } from './cloudflared.mjs';

const publicPort = Number(process.env.PUBLIC_PORT ?? 3001);
const lanPort = Number(process.env.PORT ?? 3000);
const file = (name) => fileURLToPath(new URL(`../${name}`, import.meta.url));

function readSecret(envName, name) {
  if (process.env[envName]?.trim()) return process.env[envName].trim();
  try {
    return readFileSync(file(name), 'utf8').trim();
  } catch {
    return null;
  }
}

function readNamedTunnel() {
  try {
    const config = JSON.parse(readFileSync(file('.tunnel.json'), 'utf8'));
    return config.name && config.hostname ? config : null;
  } catch {
    return null;
  }
}

const gatewayToken = readSecret('GATEWAY_TOKEN', '.gateway-token');
if (!gatewayToken) {
  console.error('No gateway token yet. Start the backend first (npm start or npm run watch).');
  process.exit(1);
}

try {
  const health = await fetch(`http://127.0.0.1:${publicPort}/api/health`, {
    headers: { authorization: `Bearer ${gatewayToken}` },
  });
  if (!health.ok) throw new Error(`HTTP ${health.status}`);
} catch (error) {
  console.error(`Public listener on 127.0.0.1:${publicPort} is not answering (${error.message}). Is the backend running?`);
  process.exit(1);
}

const named = readNamedTunnel();
const args = named
  ? ['tunnel', '--no-autoupdate', 'run', '--url', `http://127.0.0.1:${publicPort}`, named.name]
  : ['tunnel', '--no-autoupdate', '--url', `http://127.0.0.1:${publicPort}`];
const child = spawn(cloudflaredCommand(), args, { stdio: ['ignore', 'pipe', 'pipe'] });

child.on('error', (error) => {
  if (error.code === 'ENOENT') {
    console.error(INSTALL_HELP);
  } else {
    console.error('Could not start cloudflared:', error.message);
  }
  process.exit(1);
});

async function registerUrl(url) {
  const response = await fetch(`http://127.0.0.1:${lanPort}/api/tunnel`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ url }),
  });
  if (!response.ok) throw new Error(`register failed: HTTP ${response.status}`);
  return response.json();
}

const qr = (text) => QRCode.toString(text, { type: 'terminal', small: true, errorCorrectionLevel: 'L' });

let publicUrl = null;
async function announce(url) {
  publicUrl = url;
  let info;
  try {
    info = await registerUrl(url);
  } catch (error) {
    console.error(`Tunnel is up at ${url}, but the backend did not accept it (${error.message}).`);
    return;
  }

  console.log(`\nDashboard is public at ${url}${named ? '' : '  (quick tunnel: the URL changes on every run)'}\n`);
  console.log('Open the dashboard on any device (signs the browser in):');
  console.log(`  ${info.dashboardLink}\n`);
  console.log(await qr(info.dashboardLink));
  console.log('Gateway phone: scan with the iPhone camera to open MeshMapper with the URL and token filled in:');
  console.log(await qr(info.phoneLink));
  console.log(`Or enter manually in the app's Gateway tab:  URL ${url}   token ${gatewayToken}\n`);
  console.log('The same links and QR codes are in the dashboard\'s Connect panel. Press Ctrl+C to close the tunnel.\n');

  // Keep the registration fresh; the backend forgets the URL if this script dies without cleanup.
  setInterval(() => {
    if (!closing) registerUrl(url).catch(() => {});
  }, 30_000).unref();

  // A new hostname can take a few seconds to resolve; confirm the round trip once.
  for (let attempt = 0; attempt < 15; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 2000));
    try {
      const response = await fetch(`${url}/api/health`, { headers: { authorization: `Bearer ${gatewayToken}` } });
      if (response.ok) {
        console.log('Verified: the dashboard answers through the tunnel.');
        return;
      }
    } catch {
      // Not reachable yet.
    }
  }
  console.log('Could not verify the tunnel yet; it may still be propagating. Set TUNNEL_VERBOSE=1 for cloudflared logs.');
}

let announced = false;
const onOutput = (chunk) => {
  const text = chunk.toString();
  if (process.env.TUNNEL_VERBOSE) process.stderr.write(text);
  if (announced) return;
  const quick = text.match(/https:\/\/[a-z0-9-]+\.trycloudflare\.com/);
  const namedReady = named && /Registered tunnel connection/i.test(text);
  if (quick || namedReady) {
    announced = true;
    void announce(quick ? quick[0] : `https://${named.hostname}`);
  }
};
child.stdout.on('data', onOutput);
child.stderr.on('data', onOutput);

let closing = false;
async function close(signal) {
  if (closing) return;
  closing = true;
  if (publicUrl) await registerUrl(null).catch(() => {});
  child.kill(signal);
}

child.on('exit', (code) => {
  console.log(`cloudflared exited${code === null ? '' : ` with code ${code}`}.`);
  const finish = () => process.exit(code ?? 0);
  if (publicUrl && !closing) registerUrl(null).catch(() => {}).finally(finish);
  else finish();
});

for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => void close(signal));
