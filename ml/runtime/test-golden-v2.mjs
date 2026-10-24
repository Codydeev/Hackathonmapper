// Checks the JS runtime with a v2 model (map + destination) against
// predictions made by PyTorch on the Hervanta map.
//   node ml/runtime/test-golden-v2.mjs

import { readFileSync } from 'node:fs';
import { inflateSync } from 'node:zlib';
import { createMapLayer, createMovementModel } from './movement-model.js';

// Minimal PNG reader for the 8-bit RGB images ml/rasterize.py writes.
function readPng(buf) {
  let pos = 8, width = 0, height = 0, idat = [];
  while (pos < buf.length) {
    const len = buf.readUInt32BE(pos), type = buf.toString('ascii', pos + 4, pos + 8), data = buf.subarray(pos + 8, pos + 8 + len);
    if (type === 'IHDR') {
      width = data.readUInt32BE(0); height = data.readUInt32BE(4);
      if (data[8] !== 8 || data[9] !== 2 || data[12] !== 0) throw new Error('expected 8-bit RGB, not interlaced');
    } else if (type === 'IDAT') idat.push(data);
    pos += 12 + len;
  }
  const raw = inflateSync(Buffer.concat(idat)), bpp = 3, stride = width * bpp, out = new Uint8Array(height * stride);
  for (let y = 0; y < height; y++) {
    const f = raw[y * (stride + 1)], line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? out[y * stride + x - bpp] : 0, b = y ? out[(y - 1) * stride + x] : 0;
      const c = x >= bpp && y ? out[(y - 1) * stride + x - bpp] : 0;
      let v = line[x];
      if (f === 1) v += a;
      else if (f === 2) v += b;
      else if (f === 3) v += (a + b) >> 1;
      else if (f === 4) { const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c); v += pa <= pb && pa <= pc ? a : pb <= pc ? b : c; }
      out[y * stride + x] = v & 255;
    }
  }
  return { width, height, pixels: out };
}

const dir = new URL('../export/', import.meta.url);
const model = createMovementModel(JSON.parse(readFileSync(new URL('movement-model-v2.json', dir))));
const meta = JSON.parse(readFileSync(new URL('maps/hervanta.json', dir)));
const png = readPng(readFileSync(new URL('maps/hervanta.png', dir)));
if (png.width !== meta.width || png.height !== meta.height) throw new Error('map size does not match its meta');
const map = createMapLayer(png.pixels, meta, 3);
const cases = JSON.parse(readFileSync(new URL('golden-v2.json', dir)));

let worst = 0, worstPatch = 0;
const t0 = performance.now();
for (const c of cases) {
  const prep = model.prepare(c.hist, c.acc, { map, destination: c.destination });
  const patchSum = model.samplePatch(map, prep.origin, prep.th).reduce((a, b) => a + b, 0);
  worstPatch = Math.max(worstPatch, Math.abs(patchSum - c.patchSum) / (1e-3 + 1e-4 * c.patchSum));
  const p = model.predictPrepared(prep, c.h);
  c.weights.forEach((w, k) => {
    worst = Math.max(worst, Math.abs(p.weights[k] - w) / 1e-3,
      ...p.means[k].map((v, i) => Math.abs(v - c.means[k][i]) / (1e-2 + 1e-4 * Math.abs(c.means[k][i]))),
      ...p.covs[k].map((v, i) => Math.abs(v - c.covs[k][i]) / (1e-2 + 1e-3 * Math.abs(c.covs[k][i]))));
  });
}
const ms = (performance.now() - t0) / cases.length;
console.log(`${cases.length} golden cases (${cases.filter((c) => c.destination).length} with a destination): ` +
  `worst error ${worst.toFixed(3)} of tolerance, map patch ${worstPatch.toFixed(3)}, ${ms.toFixed(1)} ms each with the map`);
if (worst > 1 || worstPatch > 1) process.exit(1);
