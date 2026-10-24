"""What the route model knows about each option at a junction. Shared by
training (choice.py) and export (export_routes.py), so they cannot drift.

Arriving along directed edge d_in at a junction, every directed edge leaving
that junction is an option, including going back the way they came.
"""

import math

import numpy as np

from graph import CLASSES, PROBE_M

PARALLEL_M = 10.0   # options whose 25 m probe points are this close are one choice (sidewalk beside road)

NAMES = (['turn', 'u_turn', 'same_way', 'same_class']
         + [f'class_{c}' for c in CLASSES[1:]]
         + ['dead_end', 'named', 'log_len', 'hiking_route', 'popular'])
N_FEAT = len(NAMES)


def wrap(a):
    return (a + math.pi) % (2 * math.pi) - math.pi


def options(g, d_in):
    """Directed edges leaving the junction at the head of d_in."""
    return g.out[g.head(d_in)]


def option_groups(g, opts):
    """Group options that run side by side (probe points within PARALLEL_M)."""
    probes = [g.probe(o) for o in opts]
    group = list(range(len(opts)))
    for i in range(len(opts)):
        for j in range(i):
            if np.linalg.norm(probes[i] - probes[j]) < PARALLEL_M:
                group[i] = group[j]
                break
    return group


def features(g, d_in, opts, pop=None):
    """(len(opts), N_FEAT) features. pop: undirected edge -> traversal count
    from other people's walks, or None when there is no local data."""
    h_in = g.heading_in(d_in)
    e_in = g.edges[d_in // 2]
    counts = np.array([pop.get(o // 2, 0) for o in opts], float) if pop is not None else np.zeros(len(opts))
    total = counts.sum()
    f = np.zeros((len(opts), N_FEAT), np.float32)
    for k, o in enumerate(opts):
        e = g.edges[o // 2]
        f[k, 0] = abs(wrap(g.heading_out(o) - h_in)) / math.pi
        f[k, 1] = float(o == (d_in ^ 1))
        f[k, 2] = float(g.way_out(o) == g.way_in(d_in))
        f[k, 3] = float(e['cls'] == e_in['cls'])
        if e['cls'] > 0:
            f[k, 3 + e['cls']] = 1.0
        f[k, 9] = float(g.dead_end(o))
        f[k, 10] = float(e['name'] is not None)
        f[k, 11] = math.log(max(e['len'], 1.0)) / 5
        f[k, 12] = e['route']
        if total > 0:
            f[k, 13] = math.log((counts[k] + 1) / (total + len(opts)))
    return f


# Hand-set weights for a first look, before training: prefer going straight,
# staying on the same way and the same kind of path; avoid U-turns and dead ends.
HAND_WEIGHTS = np.zeros(N_FEAT, np.float32)
HAND_WEIGHTS[NAMES.index('turn')] = -3.0
HAND_WEIGHTS[NAMES.index('u_turn')] = -2.5
HAND_WEIGHTS[NAMES.index('same_way')] = 0.8
HAND_WEIGHTS[NAMES.index('same_class')] = 0.5
HAND_WEIGHTS[NAMES.index('dead_end')] = -1.0
HAND_WEIGHTS[NAMES.index('hiking_route')] = 0.5
