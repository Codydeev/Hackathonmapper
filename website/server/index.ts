import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { networkInterfaces } from 'node:os';
import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { extname, join, normalize, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  DEFAULT_PORT,
  GATEWAY_WARN_MS,
  MAX_BODY_BYTES,
  MAX_COORDINATE,
  SCHEMA_VERSION,
  type SceneMode,
} from '../shared/contract.ts';
import { FrameMismatchError, SceneStore } from './store.ts';
import { SimulationEngine } from './simulation.ts';
import { FieldSimulation } from './field.ts';
import {
  DASHBOARD_KEY_FILE,
  DEFAULT_PUBLIC_PORT,
  GATEWAY_TOKEN_FILE,
  LOGIN_PAGE,
  SESSION_COOKIE,
  bearerToken,
  cookieValue,
  isLoopback,
  loadDashboardKey,
  loadGatewayToken,
  secretsMatch,
  sessionCookie,
} from './access.ts';
import { validateBatch } from './validate.ts';

const PORT = Number(process.env.PORT ?? DEFAULT_PORT);
const HOST = process.env.HOST ?? '0.0.0.0';
// The tunnel-facing listener; PUBLIC_PORT=0 disables it.
const PUBLIC_PORT = Number(process.env.PUBLIC_PORT ?? DEFAULT_PUBLIC_PORT);
const PUBLIC_HOST = process.env.PUBLIC_HOST ?? '127.0.0.1';
const gatewayToken = loadGatewayToken();
const dashboardKey = loadDashboardKey();
/** Public https origin registered by `npm run tunnel`, if a tunnel is running. */
let publicUrl: string | null = null;
let publicUrlSeenAt = 0;
// The tunnel script re-registers every 30 s; drop the URL if it stops (killed without cleanup).
const PUBLIC_URL_TTL_MS = 75_000;
const here = fileURLToPath(new URL('.', import.meta.url));
const distDir = resolve(here, '..', 'dist');
const publicDir = resolve(here, '..', 'public');

const store = new SceneStore();
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
  if (publicUrl && Date.now() - publicUrlSeenAt > PUBLIC_URL_TTL_MS) {
    publicUrl = null;
    store.setPublicUrl(null);
  }
  // Addresses change when the laptop switches network; keep the dashboard's URLs current.
  store.setNetworkInfo(lanUrls(), PORT);
  // Place phones without a position from their Bluetooth links (once per second).
  store.updateEstimates();
  pushSnapshot();
  pushMap();
}, 1000);
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
        'cache-control': candidate.endsWith('index.html') ? 'no-store' : 'private, max-age=300',
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
    // The app sends its gateway token when it has one; that marks a phone checking in.
    if (secretsMatch(bearerToken(req), gatewayToken)) store.noteGatewayCheck();
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

  if (pathname === '/api/anchors' && req.method === 'POST') {
    try {
      const raw = (await readJsonBody(req)) as { id?: unknown; pin?: unknown };
      if (typeof raw?.id !== 'string' || raw.id.length === 0 || raw.id.length > 64) {
        sendJson(res, 400, { error: 'id must be a device id' });
        return true;
      }
      let pin: { x: number; y: number; z: number } | null = null;
      if (raw.pin !== null) {
        const value = raw.pin as { x?: unknown; y?: unknown; z?: unknown } | undefined;
        const coordinates = [value?.x, value?.y, value?.z];
        if (!coordinates.every((c) => typeof c === 'number' && Number.isFinite(c) && Math.abs(c) <= MAX_COORDINATE)) {
          sendJson(res, 400, { error: `pin must be {x, y, z} in meters within ±${MAX_COORDINATE}, or null` });
          return true;
        }
        pin = { x: value!.x as number, y: value!.y as number, z: value!.z as number };
      }
      if (!store.setPin(raw.id, pin)) {
        sendJson(res, 404, { error: 'That phone is not in the current scene' });
        return true;
      }
      store.updateEstimates();
      pushSnapshot(true);
      sendJson(res, 200, { ok: true, id: raw.id, pin });
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

function handleRequest(req: IncomingMessage, res: ServerResponse, pathname: string): void {
  handleApi(req, res, pathname)
    .then((handled) => (handled ? undefined : serveStatic(pathname, res)))
    .catch((error: unknown) => {
      console.error('Request failed:', error);
      if (!res.headersSent) sendJson(res, 500, { error: 'Internal server error' });
      else res.end();
    });
}

/**
 * Connection details for the dashboard's Connect panel and the tunnel script. The dashboard key
 * is only included for the laptop itself or an already signed-in public session.
 */
function connectInfo(includeDashboardKey: boolean, origin: string | null): Record<string, unknown> {
  const base = publicUrl ?? origin ?? lanUrls()[0] ?? `http://localhost:${PORT}`;
  const phoneLink =
    `meshmapper://gateway?url=${encodeURIComponent(base)}&token=${encodeURIComponent(gatewayToken)}`;
  const publicBase = publicUrl ?? origin;
  return {
    publicUrl: publicBase,
    lanUrls: lanUrls(),
    gatewayToken,
    phoneLink,
    dashboardLink:
      includeDashboardKey && publicBase ? `${publicBase}/?key=${encodeURIComponent(dashboardKey)}` : null,
  };
}

const server = createServer((req, res) => {
  const pathname = new URL(req.url ?? '/', 'http://localhost').pathname;

  // The tunnel script on this laptop registers (or clears) the public URL it obtained.
  if (pathname === '/api/tunnel' && req.method === 'POST') {
    if (!isLoopback(req)) {
      sendJson(res, 403, { error: 'Only the laptop itself can register a tunnel' });
      return;
    }
    readJsonBody(req)
      .then((raw) => {
        const url = (raw as { url?: unknown })?.url;
        if (url === null) publicUrl = null;
        else if (typeof url === 'string' && /^https:\/\/[A-Za-z0-9.-]+$/.test(url)) publicUrl = url;
        else throw Object.assign(new Error('url must be an https origin or null'), { status: 400 });
        publicUrlSeenAt = Date.now();
        if (store.getPublicUrl() !== publicUrl) {
          store.setPublicUrl(publicUrl);
          pushSnapshot(true);
        }
        sendJson(res, 200, connectInfo(true, null));
      })
      .catch((error: { status?: number; message: string }) => sendJson(res, error.status ?? 400, { error: error.message }));
    return;
  }

  if (pathname === '/api/connect' && req.method === 'GET') {
    sendJson(res, 200, connectInfo(isLoopback(req), null));
    return;
  }

  handleRequest(req, res, pathname);
});

function readFormKey(req: IncomingMessage): Promise<string> {
  return new Promise((resolveKey, rejectKey) => {
    let body = '';
    req.on('data', (chunk: Buffer) => {
      body += chunk.toString('utf8');
      if (body.length > 2048) {
        rejectKey(new Error('Form too large'));
        req.destroy();
      }
    });
    req.on('end', () => resolveKey(new URLSearchParams(body).get('key')?.trim() ?? ''));
    req.on('error', rejectKey);
  });
}

function sendLogin(res: ServerResponse, failed: boolean): void {
  const html = LOGIN_PAGE(failed);
  res.writeHead(401, {
    'content-type': 'text/html; charset=utf-8',
    'cache-control': 'no-store',
    'content-length': Buffer.byteLength(html),
  });
  res.end(html);
}

function signIn(res: ServerResponse, location: string): void {
  res.writeHead(303, { location, 'set-cookie': sessionCookie(dashboardKey), 'cache-control': 'no-store' });
  res.end();
}

// Tunnel-facing listener: the whole dashboard, but every request needs a secret. Gateway phones
// use the bearer token for health checks and uploads only; browsers use the dashboard key.
const publicServer = createServer((req, res) => {
  const url = new URL(req.url ?? '/', 'http://localhost');
  const pathname = url.pathname;
  const origin = req.headers.host ? `https://${req.headers.host}` : null;

  const bearer = bearerToken(req);
  if (bearer !== null) {
    if (!secretsMatch(bearer, gatewayToken)) {
      sendJson(res, 401, { error: 'Missing or invalid gateway token' }, { 'www-authenticate': 'Bearer' });
    } else if (pathname === '/api/health' && req.method === 'GET') {
      store.noteGatewayCheck();
      sendJson(res, 200, { status: 'ok', schemaVersion: SCHEMA_VERSION, mode: store.getMode() });
    } else if (pathname === '/api/updates' && req.method === 'POST') {
      handleRequest(req, res, pathname);
    } else {
      sendJson(res, 404, { error: 'Gateway tokens only reach /api/health and /api/updates' });
    }
    return;
  }

  if (pathname === '/login' && req.method === 'POST') {
    readFormKey(req)
      .then((key) => (secretsMatch(key, dashboardKey) ? signIn(res, '/') : sendLogin(res, true)))
      .catch(() => sendLogin(res, true));
    return;
  }

  const queryKey = url.searchParams.get('key');
  if (queryKey !== null && req.method === 'GET') {
    // Exchange the shared link's key for a cookie and drop it from the address bar.
    if (secretsMatch(queryKey, dashboardKey)) signIn(res, pathname);
    else sendLogin(res, true);
    return;
  }

  if (!secretsMatch(cookieValue(req, SESSION_COOKIE), dashboardKey)) {
    if (pathname.startsWith('/api/')) sendJson(res, 401, { error: 'Sign in with the dashboard key' });
    else sendLogin(res, false);
    return;
  }

  if (pathname === '/api/connect' && req.method === 'GET') {
    sendJson(res, 200, connectInfo(true, origin));
    return;
  }
  handleRequest(req, res, pathname);
});

if (PUBLIC_PORT > 0) {
  publicServer.listen(PUBLIC_PORT, PUBLIC_HOST, () => {
    console.log(`Public (tunnel) listener: http://${PUBLIC_HOST}:${PUBLIC_PORT}`);
    console.log(`  Gateway token in ${GATEWAY_TOKEN_FILE}, dashboard key in ${DASHBOARD_KEY_FILE}`);
    console.log('  Run `npm run tunnel` to publish it through Cloudflare.\n');
  });
  publicServer.on('error', (error) => console.error('Public listener failed:', error.message));
}

server.listen(PORT, HOST, () => {
  const urls = lanUrls();
  store.setNetworkInfo(urls, PORT);
  console.log(`\nMesh positioning dashboard`);
  console.log(`  Local:   http://localhost:${PORT}`);
  for (const url of urls) console.log(`  LAN:     ${url}`);
  console.log(`\nEnter one LAN URL in the iPhone gateway app.`);
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
  publicServer.close();
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 2000).unref();
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
