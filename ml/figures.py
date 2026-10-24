"""Pitch figures from a trained run.

    python ml/figures.py [run_dir]   # -> <run>/walk.png, <run>/search-area.png

walk.png         one real walk from the held-out Hervanta forest: the last
                 60 s, where the person really went, and the model's 90% area
                 at +30 s, +1 min and +2 min next to the constant-velocity guess
search-area.png  90% search area by horizon for the three methods
"""

import json
import sys
from pathlib import Path

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
import torch

import model as M
from export import predict_world
from train import DATA, TEST_AREA, GPS_ACC

HERE = Path(__file__).parent
SURFACE, INK, INK2, MUTED = '#fcfcfb', '#0b0b0b', '#52514e', '#c9c8c2'
BLUE, ORANGE, AQUA = '#2a78d6', '#eb6834', '#1baf7a'
SHOW_H = (30, 60, 120)
LABEL_AT = {30: (10, -4, 'left'), 60: (0, -22, 'center'), 120: (-10, -20, 'center')}   # points, for this walk

plt.rcParams.update({
    'font.family': 'sans-serif', 'font.size': 11, 'text.color': INK, 'axes.labelcolor': INK2,
    'xtick.color': INK2, 'ytick.color': INK2, 'axes.edgecolor': MUTED, 'figure.facecolor': SURFACE,
    'axes.facecolor': SURFACE, 'savefig.facecolor': SURFACE,
})


def density_grid(w, m, cov, xs, ys):
    X, Y = np.meshgrid(xs, ys)
    p = np.zeros_like(X)
    for k in range(len(w)):
        xx, xy, yy = cov[k]
        det = xx * yy - xy * xy
        dx, dy = X - m[k, 0], Y - m[k, 1]
        p += w[k] * np.exp(-(yy * dx * dx - 2 * xy * dx * dy + xx * dy * dy) / det / 2) / (2 * np.pi * np.sqrt(det))
    return X, Y, p


def level_90(p, cell):
    flat = np.sort(p.ravel())[::-1]
    mass = np.cumsum(flat) * cell
    return flat[np.searchsorted(mass, 0.9 * mass[-1])]


def pick_walk(hist, fut):
    """A clearly moving walk that turns a bit, so the picture says something."""
    moved = np.linalg.norm(hist[:, 0], axis=1)
    ahead = np.linalg.norm(fut[:, 119], axis=1)
    a, b = -hist[:, 0], fut[:, 119]
    turn = np.abs(a[:, 0] * b[:, 1] - a[:, 1] * b[:, 0]) / (moved * ahead + 1e-9)
    ok = np.where((moved > 50) & (moved < 90) & (ahead > 80) & (turn > 0.3) & (turn < 0.7))[0]
    return ok[len(ok) // 2]


def walk_figure(net, metrics, out):
    z = np.load(DATA / f'{TEST_AREA}.npz')
    i = pick_walk(z['hist'], z['fut'])
    hist, fut = z['hist'][i].astype(float), z['fut'][i].astype(float)
    fig, ax = plt.subplots(figsize=(7.5, 7.5))
    pts = np.concatenate([hist, fut[:SHOW_H[-1]]])
    c = pts.mean(0)
    r = np.abs(pts - c).max() + 90
    xs, ys = np.linspace(c[0] - r, c[0] + r, 400), np.linspace(c[1] - r, c[1] + r, 400)
    cell = (xs[1] - xs[0]) * (ys[1] - ys[0])
    for j, h in enumerate(SHOW_H):
        w, m, cov = predict_world(net, hist[None], np.array([GPS_ACC]), np.array([float(h)]))
        X, Y, p = density_grid(w[0], m[0], cov[0], xs, ys)
        lv = level_90(p, cell)
        ax.contourf(X, Y, p, levels=[lv, p.max() + 1], colors=[BLUE], alpha=0.10 + 0.08 * j)
        ax.contour(X, Y, p, levels=[lv], colors=[BLUE], linewidths=2)
        # Constant velocity with its train-tuned averaging window and spread.
        row = next(x for x in metrics if x['history'] == 'gps' and x['h'] == h and x['method'].startswith('same'))
        k = row['cv_window_s'] // M.HIST_STEP
        v = -hist[-1 - k] / row['cv_window_s']
        t = np.linspace(0, 2 * np.pi, 200)
        rad = np.array(row['cv_std']) * np.sqrt(-2 * np.log(0.1))
        heading = M.heading(hist[None])[0][0]
        ex, ey = rad[0] * np.cos(t), rad[1] * np.sin(t)
        cs, sn = np.cos(heading), np.sin(heading)
        ax.plot(v[0] * h + cs * ex - sn * ey, v[1] * h + sn * ex + cs * ey, color=ORANGE, lw=2, ls=(0, (4, 3)))
        ax.plot(*fut[h - 1], 'o', ms=9, color=INK, mec=SURFACE, mew=2, zorder=5)
        dx, dy, ha = LABEL_AT[h]
        ax.annotate(f'+{h // 60} min' if h >= 60 else f'+{h} s', fut[h - 1], xytext=(dx, dy), ha=ha,
                    textcoords='offset points', color=INK, fontsize=11, zorder=6)
    ax.plot(hist[:, 0], hist[:, 1], color=INK, lw=3, solid_capstyle='round')
    ax.plot(fut[:SHOW_H[-1], 0], fut[:SHOW_H[-1], 1], color=INK2, lw=2, ls=(0, (1, 2.5)))
    ax.plot(0, 0, 'o', ms=11, color=INK, mec=SURFACE, mew=2, zorder=5)
    ax.annotate('Bluetooth lost', (0, 0), xytext=(-8, 12), textcoords='offset points', ha='right', fontsize=11)
    ax.annotate('last 60 s', hist[5], xytext=(0, 10), textcoords='offset points', ha='center', color=INK2)
    ax.plot([], [], color=BLUE, lw=2, label='Model: 90% search area')
    ax.plot([], [], color=ORANGE, lw=2, ls=(0, (4, 3)), label='Same velocity: 90% area')
    ax.plot([], [], color=INK2, lw=2, ls=(0, (1, 2.5)), label='Where they really went')
    ax.legend(loc='upper left', frameon=False, fontsize=10)
    ax.set_aspect('equal')
    ax.set_xlim(c[0] - r, c[0] + r)
    ax.set_ylim(c[1] - r, c[1] + r)
    ax.set_xlabel('east (m)')
    ax.set_ylabel('north (m)')
    for s in ('top', 'right'):
        ax.spines[s].set_visible(False)
    ax.set_title('A real walk in the Hervanta forest the model never saw', loc='left', fontsize=13, pad=12)
    fig.tight_layout()
    fig.savefig(out / 'walk.png', dpi=180)


def area_figure(metrics, out):
    fig, ax = plt.subplots(figsize=(7.5, 4.6))
    names = [('model', 'Model', BLUE), ('same', 'Same velocity', ORANGE), ('stand', 'Stand still', AQUA)]
    for key, label, color in names:
        rows = sorted((x for x in metrics if x['history'] == 'mesh' and x['method'].startswith(key)), key=lambda x: x['h'])
        h = [x['h'] / 60 for x in rows]
        a = [x['area90'] for x in rows]
        ax.plot(h, a, color=color, lw=2, marker='o', ms=8, mec=SURFACE, mew=2)
        ax.annotate(f'{label}  {a[-1]:.1f} ha', (h[-1], a[-1]), xytext=(8, 0), textcoords='offset points',
                    va='center', color=INK, fontsize=10)
    ax.set_xlabel('minutes since the Bluetooth link was lost')
    ax.set_ylabel('90% search area (hectares)')
    ax.set_xlim(0, 3.9)
    ax.set_ylim(0, None)
    ax.grid(axis='y', color=MUTED, lw=0.6, alpha=0.6)
    for s in ('top', 'right'):
        ax.spines[s].set_visible(False)
    ax.set_title('Area a search team must cover to find the person 9 times out of 10\n'
                 'Hervanta forest, held out; history from the Bluetooth mesh (±15 m)', loc='left', fontsize=12)
    fig.tight_layout()
    fig.savefig(out / 'search-area.png', dpi=180)


def main():
    run = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / 'runs' / 'latest'
    net = M.MovementModel()
    net.load_state_dict(torch.load(run / 'model.pt'))
    net.eval()
    metrics = json.loads((run / 'metrics.json').read_text())
    walk_figure(net, metrics, run)
    area_figure(metrics, run)
    print(f'wrote {run / "walk.png"} and {run / "search-area.png"}')


if __name__ == '__main__':
    main()
