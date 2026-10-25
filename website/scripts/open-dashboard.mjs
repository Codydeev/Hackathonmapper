#!/usr/bin/env node
// Opens the dashboard on this laptop in Edge (or Chrome) with the optional Web Bluetooth features
// the dashboard's mesh node uses: reading each linked phone's signal strength (laptop distance)
// and reconnecting remembered phones without the picker (automatic gateway fallback).
// A separate profile is used because flags are ignored by a browser that is already running; the
// profile also remembers which phones the dashboard may reconnect to.
// Usage: npm run dashboard            (with npm run watch / npm start already running)

import { spawn } from 'node:child_process';
import { existsSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const port = Number(process.env.PORT ?? 3000);
const url = `http://localhost:${port}/#network`;
const profile = fileURLToPath(new URL('../.browser-profile/', import.meta.url));

const programFiles = [process.env['ProgramFiles(x86)'], process.env.ProgramFiles, process.env.LOCALAPPDATA].filter(Boolean);
const candidates =
  process.platform === 'win32'
    ? programFiles.flatMap((root) => [
        join(root, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
        join(root, 'Google', 'Chrome', 'Application', 'chrome.exe'),
      ])
    : process.platform === 'darwin'
      ? ['/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge', '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome']
      : ['/usr/bin/microsoft-edge', '/usr/bin/google-chrome', '/usr/bin/chromium'];
const browser = process.env.DASHBOARD_BROWSER ?? candidates.find((path) => existsSync(path));
if (!browser) {
  console.error('Edge or Chrome was not found. Set DASHBOARD_BROWSER to the browser executable,');
  console.error('or open the dashboard yourself and enable edge://flags/#enable-web-bluetooth-new-permissions-backend.');
  process.exit(1);
}

try {
  const health = await fetch(`http://localhost:${port}/api/health`);
  if (!health.ok) throw new Error(`HTTP ${health.status}`);
} catch (error) {
  console.error(`The dashboard is not answering on port ${port} (${error.message}). Start it with npm run watch first.`);
  process.exit(1);
}

mkdirSync(profile, { recursive: true });
const child = spawn(
  browser,
  [`--user-data-dir=${profile}`, '--enable-features=WebBluetoothNewPermissionsBackend', '--no-first-run', '--new-window', url],
  { detached: true, stdio: 'ignore' },
);
child.unref();
console.log(`Opened ${url} in ${browser.split(/[\\/]/).pop()} with Web Bluetooth signal strength and reconnection on.`);
console.log('Use "Connect a phone…" once per phone; afterwards the dashboard reconnects them by itself when the gateway is down.');
