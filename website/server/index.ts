import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { networkInterfaces } from 'node:os';
import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { extname, join, normalize, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import QRCode from 'qrcode';
import {
  DEFAULT_PORT,
  GATEWAY_WARN_MS,
  MAX_BODY_BYTES,
  SCHEMA_VERSION,
  type SceneMode,
} from '../shared/contract.ts';
import { FrameMismatchError, SceneStore } from './store.ts';
import { SimulationEngine } from './simulation.ts';
import { FieldSimulation } from './field.ts';
import { DEFAULT_GATEWAY_PORT, GATEWAY_TOKEN_FILE, hasGatewayToken, loadGatewayToken } from './gateway.ts';
import { validateBatch } from './validate.ts';

const PORT = Number(process.env.PORT ?? DEFAULT_PORT);
const HOST = process.env.HOST ?? '0.0.0.0';
// Set GATEWAY_PORT=0 to disable the tunnel-facing listener.
const GATEWAY_PORT = Number(process.env.GATEWAY_PORT ?? DEFAULT_GATEWAY_PORT);
const GATEWAY_HOST = process.env.GATEWAY_HOST ?? '127.0.0.1';
const here = fileURLToPath(new URL('.', import.meta.url));
const distDir = resolve(here, '..', 'dist');
const publicDir = resolve(here, '..', 'public');

const store = new SceneStore();
/** Public https URL of the Cloudflare tunnel, reported by `npm run tunnel` while it runs. */
let tunnelUrl: string | null = null;
const simulation = new SimulationEngine(store);
const field = new FieldSimulation(store);

const MIME_TYPES: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.map': 'application/json; charset=utf-8',
  '.webmanifest': 'application/manifest+json',
};

interface Client {
  id: number;
  res: ServerResponse;
}

const clients = new Set<Client>();
let nextClientId = 1;
let lastSentRevision = -1;

function lanUrls(): string[] {
  const urls: string[] = [];
  for (const entries of Object.values(networkInterfaces())) {
    for (const entry of entries ?? []) {
      if (entry.family === 'IPv4' && !entry.internal) {
        urls.push(`http://${entry.address}:${PORT}`);
      }
    }
  }
  return urls;
}

function sendJson(res: ServerResponse, status: number, payload: unknown, extraHeaders = {}): void {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(body),
    ...extraHeaders,
  });
  res.end(body);
}

function readJsonBody(req: IncomingMessage): Promise<unknown> {
  return new Promise((resolveBody, rejectBody) => {
    const chunks: Buffer[] = [];
    let size = 0;
    let failed = false;

    req.on('data', (chunk: Buffer) => {
      if (failed) return;
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        failed = true;
        rejectBody(Object.assign(new Error(`Request body exceeds ${MAX_BODY_BYTES} bytes`), { status: 413 }));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });

    req.on('end', () => {
      if (failed) return;
      if (chunks.length === 0) {
        rejectBody(Object.assign(new Error('Request body is required'), { status: 400 }));
        return;
      }
      try {
        resolveBody(JSON.parse(Buffer.concat(chunks).toString('utf8')));
      } catch {
        rejectBody(Object.assign(new Error('Body is not valid JSON'), { status: 400 }));
      }
    });

    req.on('error', (error) => {
      if (failed) return;
      failed = true;
      rejectBody(error);
    });
  });
}

function broadcast(payload: string): void {
  for (const client of clients) {
    if (client.res.writableLength > 1_000_000) {
      clients.delete(client);
      client.res.destroy();
      continue;
    }
    try {
      client.res.write(payload);
    } catch {
      clients.delete(client);
      client.res.destroy();
    }
  }
}

function pushSnapshot(force = false): void {
  const snapshot = store.snapshot();
  if (!force && snapshot.revision === lastSentRevision) return;
  lastSentRevision = snapshot.revision;
  broadcast(`event: snapshot\ndata: ${JSON.stringify(snapshot)}\n\n`);
}

const mapEvent = (): string => `event: map\ndata: ${JSON.stringify(field.snapshot())}\n\n`;

// The field map only exists in simulated mode; send one inactive snapshot when leaving it.
let mapWasActive = false;
function pushMap(): void {
  const active = store.getMode() === 'simulated';
  if (active || mapWasActive) broadcast(mapEvent());
  mapWasActive = active;
}

const snapshotTimer = setInterval(() => {
  // Addresses change when the laptop switches network; keep the dashboard's URLs current.
  store.setNetworkInfo(lanUrls(), PORT);
  store.updateEstimates();
  pushSnapshot();
  pushMap();
}, 1000);

/** What the dashboard's pairing QR codes open on the iPhone: the app, set up as the gateway. */
function pairingLink(url: string, token: string | null): string {
  const query = new URLSearchParams({ url });
  if (token) query.set('token', token);
  return `meshmapper://gateway?${query.toString()}`;
}

const isLoopback = (req: IncomingMessage): boolean =>
  ['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(req.socket.remoteAddress ?? '');
const heartbeatTimer = setInterval(() => broadcast(': heartbeat\n\n'), 15_000);

function openEvents(req: IncomingMessage, res: ServerResponse): void {
  res.writeHead(200, {
    'content-type': 'text/event-stream; charset=utf-8',
    'cache-control': 'no-cache, no-transform',
    connection: 'keep-alive',
    'x-accel-buffering': 'no',
  });
  res.write('retry: 2000\n\n');

  const client: Client = { id: nextClientId++, res };
  clients.add(client);
  res.write(`event: snapshot\ndata: ${JSON.stringify(store.snapshot())}\n\n`);
  res.write(mapEvent());

  const cleanup = (): void => {
    clients.delete(client);
  };

  req.on('close', cleanup);
  req.on('error', cleanup);
  res.on('error', cleanup);
}

async function serveStatic(pathname: string, res: ServerResponse): Promise<void> {
  const safeRoots = [distDir, publicDir];
  const relative = normalize(decodeURIComponent(pathname)).replace(/^([/\\])+/, '');

  for (const root of safeRoots) {
    const candidate = join(root, relative === '' ? 'index.html' : relative);
    if (!candidate.startsWith(root + sep) && candidate !== join(root, 'index.html')) continue;
    try {
      const info = await stat(candidate);
      if (!info.isFile()) continue;
      const stream = createReadStream(candidate);
      res.writeHead(200, {
        'content-type': MIME_TYPES[extname(candidate).toLowerCase()] ?? 'application/octet-stream',
        'content-length': info.size,
        'cache-control': candidate.endsWith('index.html') ? 'no-store' : 'public, max-age=300',
      });
      stream.pipe(res);
      return;
    } catch {
      continue;
    }
  }

  const fallback = join(distDir, 'index.html');
  try {
    const info = await stat(fallback);
    const stream = createReadStream(fallback);
    res.writeHead(200, {
      'content-type': MIME_TYPES['.html'],
      'content-length': info.size,
      'cache-control': 'no-store',
    });
    stream.pipe(res);
    return;
  } catch {
    const html =
      '<!doctype html><meta charset="utf-8"><title>Mesh dashboard</title>' +
      '<body style="font-family:system-ui;padding:2rem;line-height:1.5">' +
      '<h1>Frontend not built</h1>' +
      '<p>Run <code>npm install</code> then <code>npm start</code>, or use <code>npm run dev</code> ' +
      'and open the Vite dev server on port 5173.</p></body>';
    res.writeHead(503, { 'content-type': MIME_TYPES['.html'] });
    res.end(html);
  }
}

async function handleUpload(req: IncomingMessage, res: ServerResponse): Promise<void> {
  try {
    const raw = await readJsonBody(req);
    const result = validateBatch(raw);
    if (!result.ok) {
      store.recordRejected();
      sendJson(res, 400, { error: result.error });
      return;
    }
    if (store.getMode() === 'simulated') {
      sendJson(res, 409, {
        error: 'Dashboard is showing simulated data. Switch to live mode before uploading.',
      });
      return;
    }
    const merged = store.mergeLive(result.batch);
    sendJson(res, 200, { accepted: merged.accepted, ignored: merged.ignored });
  } catch (error) {
    if (error instanceof FrameMismatchError) {
      store.recordRejected();
      sendJson(res, 409, { error: error.message, expectedFrameId: error.expected });
    } else {
      const status = (error as { status?: number }).status ?? 500;
      sendJson(res, status, { error: (error as Error).message });
    }
  }
}

async function handleApi(req: IncomingMessage, res: ServerResponse, pathname: string): Promise<boolean> {
  if (pathname === '/api/health' && req.method === 'GET') {
    sendJson(res, 200, {
      status: 'ok',
      schemaVersion: SCHEMA_VERSION,
      mode: store.getMode(),
      simulationRunning: store.isSimulationRunning(),
      uploadPort: PORT,
      lanUrls: lanUrls(),
    });
    return true;
  }

  if (pathname === '/api/pairing' && req.method === 'GET') {
    // The internet URL works from any network, so it comes first when the tunnel is up.
    const targets: { kind: 'internet' | 'lan'; url: string; token: string | null }[] = [];
    if (tunnelUrl && gatewayToken) targets.push({ kind: 'internet', url: tunnelUrl, token: gatewayToken });
    // Link-local addresses (169.254.x.x, e.g. a USB-tethered phone) are unreachable over Wi-Fi.
    for (const url of lanUrls()) if (!url.includes('//169.254.')) targets.push({ kind: 'lan', url, token: null });
    const pairings = await Promise.all(
      targets.map(async ({ kind, url, token }) => {
        const link = pairingLink(url, token);
        const svg = await QRCode.toString(link, { type: 'svg', margin: 1, errorCorrectionLevel: 'M' });
        return { kind, url, link, svg };
      }),
    );
    sendJson(res, 200, { pairings, tunnelRunning: tunnelUrl !== null });
    return true;
  }

  // `npm run tunnel` on this machine reports the public URL so the pairing QR code can offer it.
  if (pathname === '/api/tunnel' && req.method === 'POST') {
    if (!isLoopback(req) || !gatewayToken || !hasGatewayToken(req, gatewayToken)) {
      sendJson(res, 403, { error: 'Only the local tunnel script may set the tunnel URL' });
      return true;
    }
    try {
      const raw = (await readJsonBody(req)) as { url?: unknown };
      if (raw?.url === null) {
        tunnelUrl = null;
      } else if (typeof raw?.url === 'string' && /^https:\/\/[a-z0-9.-]+$/i.test(raw.url)) {
        tunnelUrl = raw.url;
        console.log(`Tunnel URL for gateway pairing: ${tunnelUrl}`);
      } else {
        sendJson(res, 400, { error: 'url must be an https origin or null' });
        return true;
      }
      sendJson(res, 200, { tunnelUrl });
    } catch (error) {
      sendJson(res, (error as { status?: number }).status ?? 400, { error: (error as Error).message });
    }
    return true;
  }

  if (pathname === '/api/state' && req.method === 'GET') {
    sendJson(res, 200, store.snapshot());
    return true;
  }

  if (pathname === '/api/map' && req.method === 'GET') {
    sendJson(res, 200, field.snapshot());
    return true;
  }

  if (pathname === '/api/events' && req.method === 'GET') {
    openEvents(req, res);
    return true;
  }

  if (pathname === '/api/updates' && req.method === 'POST') {
    await handleUpload(req, res);
    return true;
  }

  if (pathname === '/api/reset' && req.method === 'POST') {
    try {
      const raw = (await readJsonBody(req)) as { mode?: unknown; confirm?: unknown };
      if (raw?.confirm !== true) {
        sendJson(res, 400, { error: 'Reset requires {"confirm": true}' });
        return true;
      }
      const mode = raw.mode === 'simulated' ? 'simulated' : 'live';
      store.reset(mode);
      if (mode === 'simulated') {
        simulation.reset();
        field.reset();
      }
      pushSnapshot(true);
      pushMap();
      sendJson(res, 200, { ok: true, mode });
    } catch (error) {
      const status = (error as { status?: number }).status ?? 400;
      sendJson(res, status, { error: (error as Error).message });
    }
    return true;
  }

  if (pathname === '/api/mode' && req.method === 'POST') {
    try {
      const raw = (await readJsonBody(req)) as { mode?: unknown };
      if (raw?.mode !== 'live' && raw?.mode !== 'simulated' && raw?.mode !== 'idle') {
        sendJson(res, 400, { error: 'mode must be "live", "simulated", or "idle"' });
        return true;
      }
      const mode = raw.mode as SceneMode;
      store.setMode(mode);
      if (mode === 'simulated') {
        simulation.reset();
        field.reset();
        store.setSimulationRunning(true);
        simulation.start();
      } else {
        simulation.stop();
      }
      pushSnapshot(true);
      pushMap();
      sendJson(res, 200, { ok: true, mode });
    } catch (error) {
      const status = (error as { status?: number }).status ?? 400;
      sendJson(res, status, { error: (error as Error).message });
    }
    return true;
  }

  if (pathname === '/api/simulation' && req.method === 'POST') {
    try {
      const raw = (await readJsonBody(req)) as {
        running?: unknown;
        stale?: unknown;
        gatewayDown?: unknown;
        reset?: unknown;
      };
      if (store.getMode() !== 'simulated') {
        sendJson(res, 409, { error: 'Simulation is only available in simulated mode' });
        return true;
      }
      if (raw?.reset === true) {
        simulation.reset();
        field.reset();
      }
      if (typeof raw?.stale === 'boolean') simulation.setSimulatedStale(raw.stale);
      if (typeof raw?.gatewayDown === 'boolean') simulation.setSimulatedGatewayDown(raw.gatewayDown);
      if (typeof raw?.running === 'boolean') {
        store.setSimulationRunning(raw.running);
        if (raw.running) simulation.start();
        else simulation.stop();
      }
      pushSnapshot(true);
      pushMap();
      sendJson(res, 200, {
        ok: true,
        running: store.isSimulationRunning(),
      });
    } catch (error) {
      const status = (error as { status?: number }).status ?? 400;
      sendJson(res, status, { error: (error as Error).message });
    }
    return true;
  }

  if (pathname.startsWith('/api/')) {
    sendJson(res, 404, { error: 'Not found' });
    return true;
  }

  return false;
}

const server = createServer((req, res) => {
  const pathname = new URL(req.url ?? '/', 'http://localhost').pathname;

  handleApi(req, res, pathname)
    .then((handled) => (handled ? undefined : serveStatic(pathname, res)))
    .catch((error: unknown) => {
      console.error('Request failed:', error);
      if (!res.headersSent) sendJson(res, 500, { error: 'Internal server error' });
      else res.end();
    });
});

// Tunnel-facing listener: only the gateway's health check and uploads, token required.
// Everything else (dashboard, SSE, mode/reset/simulation controls) stays on the LAN server.
const gatewayToken = GATEWAY_PORT > 0 ? loadGatewayToken() : '';
const gatewayServer = createServer((req, res) => {
  const pathname = new URL(req.url ?? '/', 'http://localhost').pathname;
  if (!hasGatewayToken(req, gatewayToken)) {
    sendJson(res, 401, { error: 'Missing or invalid gateway token' }, { 'www-authenticate': 'Bearer' });
    return;
  }
  if (pathname === '/api/health' && req.method === 'GET') {
    sendJson(res, 200, { status: 'ok', schemaVersion: SCHEMA_VERSION, mode: store.getMode() });
    return;
  }
  if (pathname === '/api/updates' && req.method === 'POST') {
    handleUpload(req, res).catch((error: unknown) => {
      console.error('Gateway upload failed:', error);
      if (!res.headersSent) sendJson(res, 500, { error: 'Internal server error' });
      else res.end();
    });
    return;
  }
  sendJson(res, 404, { error: 'Not found' });
});

if (GATEWAY_PORT > 0) {
  gatewayServer.listen(GATEWAY_PORT, GATEWAY_HOST, () => {
    console.log(`Gateway tunnel endpoint: http://${GATEWAY_HOST}:${GATEWAY_PORT} (token in ${GATEWAY_TOKEN_FILE})`);
    console.log('Run `npm run tunnel` to reach it from the internet through Cloudflare.\n');
  });
  gatewayServer.on('error', (error) => console.error('Gateway listener failed:', error.message));
}

server.listen(PORT, HOST, () => {
  const urls = lanUrls();
  store.setNetworkInfo(urls, PORT);
  console.log(`\nMesh positioning dashboard`);
  console.log(`  Local:   http://localhost:${PORT}`);
  for (const url of urls) console.log(`  LAN:     ${url}`);
  console.log(`\nPair the gateway phone: open the dashboard, click "Pair a gateway phone" and scan the QR code.`);
  console.log(`Gateway warning after ${GATEWAY_WARN_MS / 1000}s without a valid upload.`);
  console.log('Press Ctrl+C to stop.\n');
});

function shutdown(): void {
  clearInterval(snapshotTimer);
  clearInterval(heartbeatTimer);
  simulation.dispose();
  field.dispose();
  for (const client of clients) client.res.end();
  clients.clear();
  gatewayServer.close();
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 2000).unref();
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
