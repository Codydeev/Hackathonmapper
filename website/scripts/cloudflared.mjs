// Locates the cloudflared binary for the tunnel scripts: $CLOUDFLARED, then the copy that
// `npm run tunnel:install` downloads into website/.bin/, then whatever is on PATH.

import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

export const LOCAL_BIN_DIR = fileURLToPath(new URL('../.bin/', import.meta.url));
export const LOCAL_BINARY = `${LOCAL_BIN_DIR}cloudflared${process.platform === 'win32' ? '.exe' : ''}`;

export function cloudflaredCommand() {
  if (process.env.CLOUDFLARED?.trim()) return process.env.CLOUDFLARED.trim();
  if (existsSync(LOCAL_BINARY)) return LOCAL_BINARY;
  return 'cloudflared';
}

export const INSTALL_HELP = [
  'cloudflared was not found. Any one of these works:',
  '  npm run tunnel:install                       (downloads the official binary into website/.bin, no admin rights)',
  '  winget install --id Cloudflare.cloudflared   (Windows)',
  '  scoop install cloudflared                    (Windows, Scoop)',
  '  choco install cloudflared                    (Windows, Chocolatey; admin shell)',
  '  brew install cloudflared                     (macOS)',
  '  Manual: download from https://github.com/cloudflare/cloudflared/releases/latest and either put it on PATH',
  '          or set CLOUDFLARED to its full path.',
].join('\n');
