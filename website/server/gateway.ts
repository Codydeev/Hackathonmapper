import { randomBytes, timingSafeEqual } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import type { IncomingMessage } from 'node:http';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// The gateway listener is the only part of the backend meant to sit behind an internet tunnel
// (for example `cloudflared`). It binds to loopback so only a local tunnel process reaches it,
// serves just the gateway's routes, and requires a bearer token on every request.
export const DEFAULT_GATEWAY_PORT = 3001;
export const GATEWAY_TOKEN_FILE = resolve(fileURLToPath(new URL('.', import.meta.url)), '..', '.gateway-token');

/** GATEWAY_TOKEN from the environment, else a token generated once and kept in .gateway-token. */
export function loadGatewayToken(): string {
  const fromEnv = process.env.GATEWAY_TOKEN?.trim();
  if (fromEnv) return fromEnv;
  try {
    const saved = readFileSync(GATEWAY_TOKEN_FILE, 'utf8').trim();
    if (saved.length >= 16) return saved;
  } catch {
    // No saved token yet.
  }
  const token = randomBytes(24).toString('base64url');
  writeFileSync(GATEWAY_TOKEN_FILE, `${token}\n`, { mode: 0o600 });
  return token;
}

export function hasGatewayToken(req: IncomingMessage, token: string): boolean {
  const match = /^Bearer\s+(\S+)\s*$/i.exec(req.headers.authorization ?? '');
  if (!match) return false;
  const given = Buffer.from(match[1]);
  const expected = Buffer.from(token);
  return given.length === expected.length && timingSafeEqual(given, expected);
}
