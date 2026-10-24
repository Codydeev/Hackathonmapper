// Route model runtime. When a phone drops out of Bluetooth range, predicts
// which way the person went along the path network: 2-4 route options with
// probabilities ("60% left at the fork in 120 m, 25% straight on, 15% turned
// back"), how far along each route they probably are after t seconds, and the
// chance they left the paths. No dependencies; browser and Node.
//
//   const rp = createRoutePredictor(routeModelJson, graphJson);   // route-model.json, graphs/<area>.json
//   const pred = rp.predictRoutes(hist, accuracyMeters);          // once, when the link drops
//   const now = rp.whereAlong(pred, secondsSinceHeard);           // markers for the map, any time
//
// hist: 31 positions [x, y], 2 s apart, oldest first, in the graph's metre
// frame (toXY in movement-model.js converts GPS coordinates).

const wrap = (a) => ((a + Math.PI) % (2 * Math.PI) + 2 * Math.PI) % (2 * Math.PI) - Math.PI;

export function createRoutePredictor(model, graph) {
  const E = graph.edges.length;
  const lenOf = (e) => graph.edges[e][2];
  const nameOf = (e) => (graph.edges[e][4] >= 0 ? graph.names[graph.edges[e][4]] : null);

  // Edge polylines with cumulative distance, scaled so the end is at the edge's length.
  const geo = graph.edges.map((ed) => {
    const f = ed[6], pts = [];
    for (let i = 0; i < f.length; i += 2) pts.push([f[i], f[i + 1]]);
    const cum = [0];
    for (let i = 1; i < pts.length; i++) cum.push(cum[i - 1] + Math.hypot(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]));
    const k = cum[cum.length - 1] > 0 ? ed[2] / cum[cum.length - 1] : 1;
    return { pts, cum: cum.map((c) => c * k) };
  });
  // Point at distance s along directed edge d (from its tail).
  function at(d, s) {
    const g = geo[d >> 1], L = lenOf(d >> 1);
    const u = d & 1 ? L - s : s;
    const c = g.cum;
    if (u <= 0) return g.pts[0];
    if (u >= c[c.length - 1]) return g.pts[g.pts.length - 1];
    let i = 1;
    while (c[i] < u) i++;
    const f = (u - c[i - 1]) / Math.max(1e-9, c[i] - c[i - 1]);
    return [g.pts[i - 1][0] + f * (g.pts[i][0] - g.pts[i - 1][0]), g.pts[i - 1][1] + f * (g.pts[i][1] - g.pts[i - 1][1])];
  }
  // Points of directed edge d between distances s0 and s1 from its tail.
  function piece(d, s0, s1) {
    const g = geo[d >> 1], L = lenOf(d >> 1), out = [at(d, s0)];
    const inner = g.cum.map((c, i) => [d & 1 ? L - c : c, i]).filter(([s]) => s > s0 && s < s1);
    if (d & 1) inner.reverse();
    for (const [, i] of inner) out.push(g.pts[i]);
    out.push(at(d, s1));
    return out;
  }
  const headingOut = (d, probe = 25) => { const a = at(d, 0), b = at(d, Math.min(probe, lenOf(d >> 1))); return Math.atan2(b[1] - a[1], b[0] - a[0]); };
  const headingIn = (d, probe = 25) => { const L = lenOf(d >> 1), a = at(d, Math.max(0, L - probe)), b = at(d, L); return Math.atan2(b[1] - a[1], b[0] - a[0]); };

  // Grid of points every 5 m along every edge, for "which paths are near here".
  const CELL = 30, grid = new Map();
  geo.forEach((g, e) => {
    const L = lenOf(e), n = Math.max(2, Math.ceil(L / 5) + 1);
    for (let k = 0; k < n; k++) {
      const s = (L * k) / (n - 1), p = at(2 * e, s), key = `${Math.floor(p[0] / CELL)},${Math.floor(p[1] / CELL)}`;
      if (!grid.has(key)) grid.set(key, []);
      grid.get(key).push([e, s, p[0], p[1]]);
    }
  });
  function near(p, r) {
    const out = new Map(), c0 = Math.floor((p[0] - r) / CELL), c1 = Math.floor((p[0] + r) / CELL);
    const r0 = Math.floor((p[1] - r) / CELL), r1 = Math.floor((p[1] + r) / CELL);
    for (let i = c0; i <= c1; i++) for (let j = r0; j <= r1; j++) {
      for (const [e, s, x, y] of grid.get(`${i},${j}`) || []) {
        const dist = Math.hypot(x - p[0], y - p[1]);
        if (dist <= r && (!out.has(e) || dist < out.get(e)[0])) out.set(e, [dist, s]);
      }
    }
    return out;
  }
  const nearestDist = (p, r) => { let best = Infinity; for (const [dist] of near(p, r).values()) best = Math.min(best, dist); return best; };

  // Speed table: distance walked by time t, by recent speed.
  const S = model.speed;
  function speedBin(v) { let b = 0; while (b < S.vEdges.length && v >= S.vEdges[b]) b++; return b; }
  function distAt(q, bin, t) {
    const ts = S.t, row = S.q[q][bin];
    if (t <= ts[0]) return row[0];
    for (let i = 1; i < ts.length; i++) if (t <= ts[i]) return row[i - 1] + ((t - ts[i - 1]) / (ts[i] - ts[i - 1])) * (row[i] - row[i - 1]);
    return row[row.length - 1];
  }
  function interp(xs, ys, x) {
    if (x <= xs[0]) return ys[0];
    for (let i = 1; i < xs.length; i++) if (x <= xs[i]) return ys[i - 1] + ((x - xs[i - 1]) / (xs[i] - xs[i - 1])) * (ys[i] - ys[i - 1]);
    return ys[ys.length - 1];
  }

  // Where the walk could be on the network now: up to maxStarts directed
  // edges with the walker's position along them, plus "off the paths now".
  function locate(hist, acc) {
    const L = model.locate, n = hist.length, last = hist[n - 1];
    const recent = hist.slice(-10).map((p) => nearestDist(p, 3 * L.offPathM)).sort((a, b) => a - b);
    const offNow = recent[recent.length >> 1] > L.offPathM;
    const R = Math.max(L.minR, L.accMul * acc), sig2 = acc * acc + L.sigma0 * L.sigma0;
    let cands = [...near(last, R)].map(([e, [dist, s]]) => ({ e, s, w: Math.exp((-dist * dist) / (2 * sig2)) }));
    if (!cands.length) cands = [...near(last, 4 * R)].map(([e, [dist, s]]) => ({ e, s, w: Math.exp((-dist * dist) / (2 * sig2 * 16)) }));
    cands.sort((a, b) => b.w - a.w);
    const tot = cands.reduce((a, c) => a + c.w, 0);
    cands = cands.filter((c, i) => i < L.maxStarts && c.w / tot >= L.minShare);
    const t2 = cands.reduce((a, c) => a + c.w, 0);
    const back = hist[n - 1], from = hist[Math.max(0, n - 11)];
    const moved = Math.hypot(back[0] - from[0], back[1] - from[1]) >= L.movedM;
    const th = Math.atan2(back[1] - from[1], back[0] - from[0]);
    const pBack = moved ? model.back.moving : model.back.stopped;
    const starts = [];
    for (const c of cands) {
      const share = c.w / t2, Le = lenOf(c.e);
      const a = at(2 * c.e, Math.max(0, c.s - 5)), b = at(2 * c.e, Math.min(Le, c.s + 5));
      const tangent = Math.atan2(b[1] - a[1], b[0] - a[0]);
      const fwdAligned = !moved || Math.cos(th - tangent) >= 0;
      const pFwd = moved ? (fwdAligned ? 1 - pBack : pBack) : 0.5;
      starts.push({ d: 2 * c.e, s: c.s, p: share * pFwd, back: moved && !fwdAligned });
      starts.push({ d: 2 * c.e + 1, s: Le - c.s, p: share * (1 - pFwd), back: moved && fwdAligned });
    }
    return { starts: starts.filter((s) => s.p > 0), offNow, moved, th };
  }

  // Best-first expansion over the turn tables, up to how far they could walk.
  function rollout(starts, dmax) {
    const R = model.rollout, root = { d: -1, p: 1, end: 0, children: [], parent: null };
    const heap = [];
    const push = (x) => { heap.push(x); heap.sort((a, b) => a.p - b.p); };
    for (const s of starts) {
      const node = { d: s.d, p: s.p, start: s.s, end: lenOf(s.d >> 1) - s.s, children: [], parent: root, back: s.back };
      root.children.push(node);
      push(node);
    }
    let leaves = starts.length;
    while (heap.length) {
      const x = heap.pop();
      if (x.end >= dmax || leaves >= R.maxLeaves) continue;
      const o0 = graph.turnOff[x.d], o1 = graph.turnOff[x.d + 1];
      let added = 0;
      for (let k = o0; k < o1; k++) {
        const p = x.p * graph.turnP[k];
        if (p < R.prune) continue;
        const d = graph.turnTo[k];
        const c = { d, p, start: 0, end: x.end + lenOf(d >> 1), children: [], parent: x };
        x.children.push(c);
        push(c);
        added++;
      }
      if (added) leaves += added - 1;
    }
    return root;
  }

  const distAlong = (x) => x.end;   // distance from the walker to the end of node x's edge
  function probePoint(x) {
    const len = lenOf(x.d >> 1) - x.start;
    return at(x.d, x.start + Math.min(len, model.merge.probeM));
  }
  function clusters(children) {
    const M = model.merge, out = [];
    for (const c of [...children].sort((a, b) => b.p - a.p)) {
      const pc = probePoint(c);
      const hit = out.find((g) => Math.hypot(g.probe[0] - pc[0], g.probe[1] - pc[1]) < M.parallelM);
      if (hit) { hit.members.push(c); hit.p += c.p; } else out.push({ members: [c], p: c.p, probe: pc });
    }
    return out;
  }

  // Merge the tree into 2-4 routes, splitting at the earliest real forks.
  function merge(root, total) {
    const M = model.merge;
    const groups = [{ anchors: [root], excluded: new Set(), fork: null, via: null }];
    const live = (x, g) => x.children.filter((c) => !g.excluded.has(c));
    function firstFork(g) {
      let x = g.anchors.reduce((a, b) => (b.p > a.p ? b : a));
      while (x) {
        const cl = clusters(live(x, g)).filter((c) => c.p >= M.minShare * total);
        if (cl.length >= 2) return { at: x, clusters: cl, dist: x === root ? 0 : distAlong(x) };
        const kids = live(x, g);
        x = kids.length ? kids.reduce((a, b) => (b.p > a.p ? b : a)) : null;
      }
      return null;
    }
    for (;;) {
      if (groups.length >= M.maxRoutes) break;
      let best = null;
      for (const g of groups) {
        const f = firstFork(g);
        if (f && (!best || f.dist < best.f.dist)) best = { g, f };
      }
      if (!best) break;
      const { g, f } = best;
      const [stay, ...others] = f.clusters;   // sorted by mass, heaviest stays
      // The route that stays is named after this fork, unless the "fork" is
      // just which path they are on (root): then a later fork names it.
      if (!g.via && f.at !== root) { g.fork = f.at; g.via = stay.members[0]; }
      let split = 0;
      for (const c of others) {
        if (groups.length >= M.maxRoutes) break;
        for (const m of c.members) g.excluded.add(m);
        groups.push({ anchors: c.members, excluded: new Set(), fork: f.at, via: c.members[0] });
        split++;
      }
      if (!split) break;
    }
    return groups.map((g) => {
      const mass = g.anchors.reduce((a, x) => a + x.p, 0) - [...g.excluded].reduce((a, x) => a + x.p, 0);
      // The drawn line: ancestors of the heaviest anchor, then its heaviest path.
      let x = g.anchors.reduce((a, b) => (b.p > a.p ? b : a));
      const chain = [];
      for (let y = x; y && y !== root; y = y.parent) chain.unshift(y);
      while (x) {
        const kids = live(x, g);
        x = kids.length ? kids.reduce((a, b) => (b.p > a.p ? b : a)) : null;
        if (x) chain.push(x);
      }
      return { mass, chain, fork: g.fork, via: g.via };
    }).filter((r) => r.chain.length && r.mass > 0);
  }

  function describe(r, heading, moved) {
    const first = r.chain[0];
    let name = null;
    for (const x of r.chain) { name = nameOf(x.d >> 1); if (name) break; }
    const along = name ? ` · ${name}` : '';
    if (first.back && (!r.fork || r.fork.d === -1)) return { turn: 'back', text: `Turned back${along}` };
    if (!r.fork || !r.via || r.fork.d === -1) {
      // No fork names it: say which way the route heads from where they were,
      // relative to how they were walking, or by compass if they had stopped.
      if (r.cum.length < 2) return { turn: 'along', text: `Along this path${along}` };
      const p = pointAlong(r, Math.min(60, r.cum[r.cum.length - 1])), o = r.line[0];
      if (!moved) {
        const deg = ((90 - (Math.atan2(p[1] - o[1], p[0] - o[0]) * 180) / Math.PI) + 360) % 360;
        const compass = ['north', 'northeast', 'east', 'southeast', 'south', 'southwest', 'west', 'northwest'][Math.round(deg / 45) % 8];
        return { turn: 'along', text: `Heading ${compass}${along}` };
      }
      const a = wrap(Math.atan2(p[1] - o[1], p[0] - o[0]) - heading), deg = (Math.abs(a) * 180) / Math.PI;
      const side = a > 0 ? 'left' : 'right';
      const words = deg < 30 ? 'Ahead' : deg < 150 ? `Off to the ${side}` : 'Back the way they came';
      return { turn: deg < 30 ? 'along' : deg < 150 ? side : 'back', text: `${words}${along}` };
    }
    const a = wrap(headingOut(r.via.d) - headingIn(r.fork.d)), deg = (Math.abs(a) * 180) / Math.PI;
    const side = a > 0 ? 'left' : 'right';
    const turn = deg < 15 ? 'straight' : deg < 45 ? `slight ${side}` : deg <= 145 ? side : 'back';
    const words = { straight: 'Straight on', 'slight left': 'Bear left', 'slight right': 'Bear right', left: 'Left', right: 'Right', back: 'Back' }[turn];
    const dist = Math.max(0, Math.round(r.fork.end / 10) * 10);
    return { turn, text: `${words} at the fork in ${dist} m${along}`, forkIn: dist, first: first.d };
  }

  function predictRoutes(hist, acc) {
    const n = hist.length, last = hist[n - 1], first = hist[0];
    const v = Math.hypot(last[0] - first[0], last[1] - first[1]) / ((n - 1) * 2);
    const bin = speedBin(v);
    const dmax = distAt('q90', bin, model.rollout.horizon) + 30;
    const loc = locate(hist, acc);
    const off = model.offPath, pOff = interp(off.t, loc.offNow ? off.off : off.on, model.rollout.horizon);
    if (!loc.starts.length) return { routes: [], offPath: 1, bin, offNow: true };
    const root = rollout(loc.starts, dmax);
    const total = loc.starts.reduce((a, s) => a + s.p, 0);
    const routes = merge(root, total).map((r) => {
      // Line from the walker's position along the chain of edges.
      const pts = [], cum = [];
      let dist = 0;
      for (const x of r.chain) {
        const seg = piece(x.d, x.start, lenOf(x.d >> 1));
        for (const p of seg) {
          if (pts.length) dist += Math.hypot(p[0] - pts[pts.length - 1][0], p[1] - pts[pts.length - 1][1]);
          pts.push(p); cum.push(dist);
        }
      }
      const route = { p: (r.mass / total) * (1 - pOff), line: pts, cum };
      return Object.assign(route, describe({ ...r, ...route }, loc.th, loc.moved));
    }).sort((a, b) => b.p - a.p);
    return { routes: dedupe(routes), offPath: pOff, offNow: loc.offNow, bin, speed: v, origin: last };
  }

  // Standing at a junction puts the start on several of its edges, which can
  // give the same route twice: merge routes that stay within 20 m of each
  // other all the way.
  function dedupe(routes) {
    const out = [];
    for (const r of routes) {
      const twin = out.find((o) => {
        const L = Math.min(o.cum[o.cum.length - 1], r.cum[r.cum.length - 1]);
        for (let s = 0; s <= L; s += 25) {
          const a = pointAlong(o, s), b = pointAlong(r, s);
          if (Math.hypot(a[0] - b[0], a[1] - b[1]) > 20) return false;
        }
        return true;
      });
      if (twin) twin.p += r.p; else out.push(r);
    }
    return out;
  }

  function pointAlong(r, s) {
    const c = r.cum;
    if (s <= 0) return r.line[0];
    if (s >= c[c.length - 1]) return r.line[r.line.length - 1];
    let i = 1;
    while (c[i] < s) i++;
    const f = (s - c[i - 1]) / Math.max(1e-9, c[i] - c[i - 1]);
    return [r.line[i - 1][0] + f * (r.line[i][0] - r.line[i - 1][0]), r.line[i - 1][1] + f * (r.line[i][1] - r.line[i - 1][1])];
  }
  function band(r, s0, s1) {
    const out = [pointAlong(r, s0)];
    r.cum.forEach((c, i) => { if (c > s0 && c < s1) out.push(r.line[i]); });
    out.push(pointAlong(r, s1));
    return out;
  }

  // Where along each route they probably are after t seconds.
  function whereAlong(pred, t) {
    const q10 = distAt('q10', pred.bin, t), q50 = distAt('q50', pred.bin, t), q90 = distAt('q90', pred.bin, t);
    return pred.routes.map((r) => {
    const end = r.cum[r.cum.length - 1];
      return { point: pointAlong(r, q50), band: band(r, q10, q90), atEnd: q50 >= end, dist: { q10, q50, q90 } };
    });
  }

  return { predictRoutes, whereAlong, locate, near, edgeCount: E };
}
