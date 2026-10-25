#!/usr/bin/env node
// Publishes the dashboard through Cloudflare. The tunnel points at the backend's public listener
// (127.0.0.1:3001), which requires the dashboard key for browsers and the gateway token for phones.
// - With .tunnel.json (from `npm run tunnel:setup -- <hostname>`): a named tunnel on your domain.
// - Without it: a quick tunnel on a random https://….trycloudflare.com URL (no account needed).
// Requires `cloudflared` (see scripts/cloudflared.mjs; `npm run tunnel:install` fetches it) and a
// running backend.
//
// A watchdog checks the public URL every 20 s and restarts cloudflared after three failures in a
// row. Quick tunnels cannot reconnect once Cloudflare drops them (the hostname is deleted), so a
// restart there means a new URL: the dashboard's QR codes update, but the gateway phone must rescan.
// TUNNEL_PROTOCOL picks cloudflared's transport (default http2 over TCP 443; quic uses UDP and
// drops more often on restrictive networks).

import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import QRCode from 'qrcode';
import { INSTALL_HELP, cloudflaredCommand } from './cloudflared.mjs';

const publicPort = Number(process.env.PUBLIC_PORT ?? 3001);
const lanPort = Number(process.env.PORT ?? 3000);
const protocol = process.env.TUNNEL_PROTOCOL ?? 'http2';
const CHECK_INTERVAL_MS = 20_000;
const FAILURES_BEFORE_RESTART = 3;
const RATE_LIMITED = 'rate limited';
const RATE_LIMIT_WAIT_MS = 5 * 60_000;
const file = (name) => fileURLToPath(new URL(`../${name}`, import.meta.url));
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const stamp = () => new Date().toLocaleTimeString();

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

async function healthy(base, timeoutMs = 10_000) {
  try {
    const response = await fetch(`${base}/api/health`, {
      headers: { authorization: `Bearer ${gatewayToken}` },
      signal: AbortSignal.timeout(timeoutMs),
    });
    return response.ok;
  } catch {
    return false;
  }
}

if (!(await healthy(`http://127.0.0.1:${publicPort}`))) {
  console.error(`Public listener on 127.0.0.1:${publicPort} is not answering. Is the backend running?`);
  process.exit(1);
}

const named = readNamedTunnel();

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

let child = null;
let publicUrl = null;
let previousUrl = null;
let closing = false;

async function unpublish() {
  if (!publicUrl) return;
  publicUrl = null;
  await registerUrl(null).catch(() => {});
}

async function close(signal) {
  if (closing) return;
  closing = true;
  await unpublish();
  child?.kill(signal);
  process.exit(0);
}

for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => void close(signal));

async function announce(url) {
  let info;
  try {
    info = await registerUrl(url);
  } catch (error) {
    console.error(`Tunnel is up at ${url}, but the backend did not accept it (${error.message}).`);
    return;
  }
  publicUrl = url;

  if (previousUrl && previousUrl !== url) {
    console.log(`\n[${stamp()}] The quick tunnel came back on a NEW address. Rescan the gateway QR code on the phone`);
    console.log('(dashboard Connect panel or Gateway page), or the phone keeps uploading to the old, dead URL.');
  }
  previousUrl = url;

  console.log(`\nDashboard is public at ${url}${named ? '' : '  (quick tunnel: the URL changes when the tunnel restarts)'}\n`);
  console.log('Open the dashboard on any device (signs the browser in):');
  console.log(`  ${info.dashboardLink}\n`);
  console.log(await qr(info.dashboardLink));
  console.log('Gateway phone: scan with the iPhone camera to open MeshMapper with the URL and token filled in:');
  console.log(await qr(info.phoneLink));
  console.log(`Or enter manually in the app's Gateway tab:  URL ${url}   token ${gatewayToken}\n`);
  console.log('The same links and QR codes are in the dashboard\'s Connect panel. Press Ctrl+C to close the tunnel.\n');
}

/** Runs one cloudflared process; resolves when it exits or the watchdog gives up on it. */
function runTunnel() {
  return new Promise((resolve) => {
    const args = named
      ? ['tunnel', '--no-autoupdate', '--protocol', protocol, 'run', '--url', `http://127.0.0.1:${publicPort}`, named.name]
      : ['tunnel', '--no-autoupdate', '--protocol', protocol, '--url', `http://127.0.0.1:${publicPort}`];
    const proc = spawn(cloudflaredCommand(), args, { stdio: ['ignore', 'pipe', 'pipe'] });
    child = proc;
    let url = null;
    let watchdog = null;
    let finished = false;

    const finish = (reason) => {
      if (finished) return;
      finished = true;
      clearInterval(watchdog);
      if (proc.exitCode === null) proc.kill();
      resolve(reason);
    };

    proc.on('error', (error) => {
      if (error.code === 'ENOENT') {
        console.error(INSTALL_HELP);
        process.exit(1);
      }
      console.error('Could not start cloudflared:', error.message);
      finish('error');
    });
    proc.on('exit', (code) => finish(`cloudflared exited${code === null ? '' : ` with code ${code}`}`));

    async function startWatching(base) {
      // A new hostname can take a few seconds to resolve; wait for the first good round trip.
      let up = false;
      for (let attempt = 0; attempt < 20 && !finished && !closing; attempt += 1) {
        await sleep(2000);
        if ((up = await healthy(base))) break;
      }
      if (finished || closing) return;
      if (!up) {
        finish('the new tunnel never became reachable');
        return;
      }
      await announce(base);
      console.log(`[${stamp()}] Verified: the dashboard answers through the tunnel (${protocol}). Watching it every ${CHECK_INTERVAL_MS / 1000} s.`);

      let failures = 0;
      watchdog = setInterval(async () => {
        if (closing || finished) return;
        if (await healthy(base)) {
          if (failures > 0) console.log(`[${stamp()}] Tunnel reachable again.`);
          failures = 0;
          // Keep the registration fresh; the backend forgets the URL after 75 s without it.
          registerUrl(base).catch(() => {});
          return;
        }
        failures += 1;
        console.log(`[${stamp()}] Tunnel check failed (${failures}/${FAILURES_BEFORE_RESTART}).`);
        if (failures >= FAILURES_BEFORE_RESTART) finish('the public URL stopped answering');
      }, CHECK_INTERVAL_MS);
    }

    const onOutput = (chunk) => {
      const text = chunk.toString();
      if (process.env.TUNNEL_VERBOSE) process.stderr.write(text);
      // trycloudflare.com limits how many quick tunnels one address may create.
      if (/status 429/.test(text)) finish(RATE_LIMITED);
      if (url) return;
      const quick = text.match(/https:\/\/[a-z0-9-]+\.trycloudflare\.com/);
      const namedReady = named && /Registered tunnel connection/i.test(text);
      if (!quick && !namedReady) return;
      url = quick ? quick[0] : `https://${named.hostname}`;
      void startWatching(url);
    };
    proc.stdout.on('data', onOutput);
    proc.stderr.on('data', onOutput);
  });
}

for (let restarts = 0; !closing; restarts += 1) {
  const reason = await runTunnel();
  if (closing) break;
  await unpublish();
  if (reason === RATE_LIMITED) {
    // Retrying quickly only extends the limit, so wait minutes, not seconds.
    console.log(`\n[${stamp()}] Cloudflare is rate-limiting quick tunnels from this address (HTTP 429): too many were`);
    console.log(`created recently. Trying again in ${RATE_LIMIT_WAIT_MS / 60_000} min. A named tunnel (npm run tunnel:setup) avoids this limit.`);
    await sleep(RATE_LIMIT_WAIT_MS);
    continue;
  }
  const delay = Math.min(30_000, 2000 * 2 ** Math.min(restarts, 4));
  console.log(`\n[${stamp()}] Tunnel down: ${reason}. Restarting in ${delay / 1000} s…`);
  await sleep(delay);
}
