#!/usr/bin/env node
// One command for the demo laptop: install dependencies the first time, rebuild the dashboard
// only if its sources changed, start the backend and open the dashboard in the browser.
// Usage: npm run demo        (PORT=3000 by default)

import { spawn, spawnSync } from 'node:child_process';
import { existsSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const windows = process.platform === 'win32';
const npm = windows ? 'npm.cmd' : 'npm';
const port = Number(process.env.PORT ?? 3000);

function run(command, args) {
  const result = spawnSync(command, args, { cwd: root, stdio: 'inherit', shell: windows });
  if (result.status !== 0) process.exit(result.status ?? 1);
}

function newest(path) {
  if (!existsSync(path)) return 0;
  const info = statSync(path);
  if (!info.isDirectory()) return info.mtimeMs;
  return readdirSync(path).reduce((latest, name) => Math.max(latest, newest(join(path, name))), 0);
}

if (!existsSync(join(root, 'node_modules'))) {
  console.log('Installing dependencies (first run only)…');
  run(npm, ['install']);
}

const sources = Math.max(newest(join(root, 'src')), newest(join(root, 'shared')), newest(join(root, 'index.html')));
if (newest(join(root, 'dist', 'index.html')) < sources) {
  console.log('Building the dashboard…');
  run(npm, ['run', 'build']);
}

const server = spawn(process.execPath, ['--import', 'tsx', 'server/index.ts'], { cwd: root, stdio: 'inherit' });
server.on('exit', (code) => process.exit(code ?? 0));
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.kill(signal));

// Open the dashboard once the server answers.
const url = `http://localhost:${port}`;
for (let attempt = 0; attempt < 40; attempt += 1) {
  await new Promise((resolve) => setTimeout(resolve, 250));
  try {
    if ((await fetch(`${url}/api/health`)).ok) {
      const [command, args] = windows
        ? ['cmd', ['/c', 'start', '', url]]
        : [process.platform === 'darwin' ? 'open' : 'xdg-open', [url]];
      spawn(command, args, { stdio: 'ignore', detached: true }).unref();
      break;
    }
  } catch {
    // Not up yet.
  }
}
