import { randomBytes, timingSafeEqual } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import type { IncomingMessage } from 'node:http';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// The public listener is the only part of the backend meant to sit behind an internet tunnel
// (`cloudflared`). It binds to loopback so only a local tunnel process reaches it, and every
// request must carry a secret:
// - gateway phones send the gateway token as `Authorization: Bearer <token>`;
// - browsers send the dashboard key once (`/?key=…` or the login form) and then a cookie.
export const DEFAULT_PUBLIC_PORT = 3001;
export const SESSION_COOKIE = 'mesh_key';
/** Sent by `npm run tunnel` with its health checks, which must not count as a gateway check-in. */
export const TUNNEL_PROBE_HEADER = 'x-mesh-tunnel-probe';

const websiteDir = resolve(fileURLToPath(new URL('.', import.meta.url)), '..');
export const GATEWAY_TOKEN_FILE = resolve(websiteDir, '.gateway-token');
export const DASHBOARD_KEY_FILE = resolve(websiteDir, '.dashboard-key');

/** The environment value, else a secret generated once and kept in a git-ignored file. */
function loadSecret(envName: string, file: string): string {
  const fromEnv = process.env[envName]?.trim();
  if (fromEnv) return fromEnv;
  try {
    const saved = readFileSync(file, 'utf8').trim();
    if (saved.length >= 16) return saved;
  } catch {
    // Not created yet.
  }
  const secret = randomBytes(24).toString('base64url');
  writeFileSync(file, `${secret}\n`, { mode: 0o600 });
  return secret;
}

export const loadGatewayToken = (): string => loadSecret('GATEWAY_TOKEN', GATEWAY_TOKEN_FILE);
export const loadDashboardKey = (): string => loadSecret('DASHBOARD_KEY', DASHBOARD_KEY_FILE);

export function secretsMatch(given: string | null | undefined, expected: string): boolean {
  if (!given || !expected) return false;
  const a = Buffer.from(given);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

export function bearerToken(req: IncomingMessage): string | null {
  return /^Bearer\s+(\S+)\s*$/i.exec(req.headers.authorization ?? '')?.[1] ?? null;
}

export function cookieValue(req: IncomingMessage, name: string): string | null {
  for (const part of (req.headers.cookie ?? '').split(';')) {
    const [key, ...rest] = part.trim().split('=');
    if (key !== name) continue;
    // A malformed escape (`%E0%A4%A`) throws; uncaught, one request through the tunnel would stop
    // the server and lose the whole in-memory scene.
    try {
      return decodeURIComponent(rest.join('='));
    } catch {
      return null;
    }
  }
  return null;
}

/**
 * Host names a DNS-rebinding page cannot take over: IP literals, `localhost`, single-label names
 * and local-only suffixes. A hostile site rebinding its own domain to the laptop's address would
 * otherwise read `/api/connect` (the gateway token) or drive the LAN API. More names can be
 * allowed with TRUSTED_HOSTS (comma separated).
 */
export function isTrustedHost(req: IncomingMessage, extra: readonly string[] = []): boolean {
  const host = (req.headers.host ?? '').trim().toLowerCase();
  if (host === '') return true; // HTTP/1.0 clients; every browser sends Host.
  // A trailing dot is the fully qualified form of the same name (`localhost.`, `laptop.local.`).
  const name = host.startsWith('[') ? host.slice(0, host.indexOf(']') + 1) : host.replace(/:\d+$/, '').replace(/\.$/, '');
  if (name.startsWith('[') || /^\d{1,3}(\.\d{1,3}){3}$/.test(name)) return true;
  if (name === 'localhost' || !name.includes('.')) return true;
  if (['.localhost', '.local', '.lan', '.home.arpa', '.internal'].some((suffix) => name.endsWith(suffix))) return true;
  return extra.includes(name);
}

/**
 * Cross-site requests from another page in the operator's browser: browsers send Origin with
 * every cross-origin POST, so a state-changing request whose Origin names another host (or
 * `null`) did not come from this dashboard. Phones and scripts send no Origin.
 */
export function isCrossSite(req: IncomingMessage): boolean {
  const origin = req.headers.origin;
  if (origin === undefined) return false;
  try {
    // Hostnames only: the Vite dev server (another port) proxies the dashboard's own requests.
    const host = (req.headers.host ?? '').toLowerCase().replace(/:\d+$/, '');
    return new URL(origin).hostname.toLowerCase() !== host;
  } catch {
    return true;
  }
}

/** HttpOnly + SameSite=Lax keeps the key away from scripts and cross-site POSTs. */
export function sessionCookie(key: string): string {
  return `${SESSION_COOKIE}=${encodeURIComponent(key)}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=2592000`;
}

export function isLoopback(req: IncomingMessage): boolean {
  const address = req.socket.remoteAddress ?? '';
  return address === '127.0.0.1' || address === '::1' || address === '::ffff:127.0.0.1';
}

export const LOGIN_PAGE = (failed: boolean): string => `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Mesh Positioning – sign in</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #000; color: #fff;
         font: 14px/1.5 system-ui, -apple-system, "Segoe UI", sans-serif; }
  form { width: min(360px, calc(100% - 32px)); padding: 24px; border: 1px solid #303030; border-radius: 12px; background: #0a0a0a; }
  h1 { margin: 0 0 6px; font-size: 18px; }
  p { margin: 0 0 16px; color: #a8a8a8; }
  input, button { width: 100%; box-sizing: border-box; font: inherit; padding: 9px 11px; border-radius: 8px; }
  input { border: 1px solid #303030; background: #000; color: #fff; margin-bottom: 10px; }
  button { border: 1px solid #4da3ff; background: #0f2a47; color: #fff; cursor: pointer; }
  .error { color: #ff6b6b; }
</style>
</head>
<body>
<form method="post" action="/login">
  <h1>Mesh Positioning</h1>
  <p>Enter the dashboard key printed by <code>npm run tunnel</code> on the laptop, or open the dashboard link it shows.</p>
  ${failed ? '<p class="error">That key was not accepted.</p>' : ''}
  <input name="key" type="password" autocomplete="current-password" placeholder="Dashboard key" autofocus required />
  <button type="submit">Open dashboard</button>
</form>
</body>
</html>`;
