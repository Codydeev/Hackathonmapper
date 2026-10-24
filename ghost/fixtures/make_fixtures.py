"""Writes the Ghost Mode replay scenarios in this folder (standard library only, deterministic).

    python3 -I ghost/fixtures/make_fixtures.py

Each scenario is a timeline of observations and motion hints, the true paths, and checks
(GhostScenario in ios/MeshCore/Sources/MeshCore/Ghost/GhostReplay.swift). The checks state
requirements (status, what is shown, truth inside the 95% circle, what a recovery does), not
snapshots of numbers, so refitting the motion model does not rewrite them.
"""
import json
import math
import random
from pathlib import Path

HERE = Path(__file__).parent


def path(start, legs, t0=0):
    """legs: (seconds, speed m/s, heading degrees clockwise from north). Rows [t, x, z] every 1 s."""
    x, z = start
    rows = [[t0, x, z]]
    t = t0
    for seconds, speed, heading in legs:
        h = math.radians(heading)
        for _ in range(seconds):
            t += 1
            x += speed * math.sin(h)
            z += speed * math.cos(h)
            rows.append([t, round(x, 3), round(z, 3)])
    return rows


def at(rows, t):
    for r in rows:
        if r[0] == t:
            return r
    raise KeyError(t)


def observe(rng, truth, pid, times, sigma, source, noise=None, age=0.0):
    noise = sigma * 0.75 if noise is None else noise
    out = []
    for t in times:
        _, x, z = at(truth, t)
        out.append({'t': t, 'id': pid, 'observe': {
            'x': round(x + rng.gauss(0, noise), 2), 'z': round(z + rng.gauss(0, noise), 2),
            'sigma': sigma, 'source': source, **({'age': age} if age else {})}})
    return out


def hints(rng, truth, pid, times, speed_bias=1.0, heading_bias=0.0):
    out = []
    for t in times:
        _, x0, z0 = at(truth, t - 1)
        _, x1, z1 = at(truth, t)
        vx, vz = x1 - x0, z1 - z0
        speed = math.hypot(vx, vz)
        if speed < 0.2:
            out.append({'t': t, 'id': pid, 'motion': {'stationary': True}})
            continue
        heading = math.atan2(vx, vz) + math.radians(heading_bias) + rng.gauss(0, math.radians(10))
        out.append({'t': t, 'id': pid, 'motion': {
            'stationary': False, 'speed': round(speed * speed_bias * (1 + rng.gauss(0, 0.05)), 3),
            'heading': round(heading, 4), 'speedSigma': 0.2, 'headingSigma': 0.3}})
    return out


def check(t, pid, **kw):
    return {'t': t, 'id': pid, **kw}


def scenario(name, description, events, truth, checks, **extra):
    return {'name': name, 'description': description, 'events': events, 'truth': truth, 'checks': checks, **extra}


def build():
    out = []

    rng = random.Random(1)
    b = path((0, 0), [(240, 1.3, 90)])
    out.append(scenario(
        'walk-out-of-range',
        'B walks east, seen over Bluetooth every second, walks out of range at 60 s and is heard '
        'again at 150 s. The demo beat: last seen stays put, the prediction grows, then is dropped.',
        observe(rng, b, 'B', range(0, 61), 8, 'bluetooth') + observe(rng, b, 'B', range(150, 171), 8, 'bluetooth'),
        {'B': b},
        [check(30, 'B', status='live', basis='observed'),
         check(60, 'B', status='live', lastObservedT=60),
         check(70, 'B', status='ghost', basis='extrapolated', lastObservedT=60, truthInsideR95=True),
         check(100, 'B', status='ghost', lastObservedT=60, truthInsideR95=True),
         check(149, 'B', status='ghost', lastObservedT=60, truthInsideR95=True, confidenceMax=0.9),
         check(150, 'B', recovery='fused', recoveryInsideR95=True),
         check(151, 'B', status='live', lastObservedT=151, note='prediction dropped once heard again')],
        end=170))

    rng = random.Random(2)
    b = path((0, 0), [(80, 1.3, 90), (160, 1.3, 0)])
    out.append(scenario(
        'turn-while-hidden',
        'B walks east, is lost at 60 s, turns north at 80 s unseen and is heard again at 140 s.',
        observe(rng, b, 'B', range(0, 61), 8, 'bluetooth') + observe(rng, b, 'B', range(140, 151), 8, 'bluetooth'),
        {'B': b},
        [check(90, 'B', status='ghost', truthInsideR95=True),
         check(139, 'B', status='ghost', lastObservedT=60, truthInsideR95=True),
         check(140, 'B', recovery='fused'),
         check(141, 'B', status='live')],
        end=150))

    rng = random.Random(3)
    b = path((0, 0), [(65, 1.3, 90), (200, 0, 90)])
    out.append(scenario(
        'stop-while-hidden',
        'B walks east, is lost at 60 s, stops at 65 s and stands until heard again at 180 s.',
        observe(rng, b, 'B', range(0, 61), 8, 'bluetooth') + observe(rng, b, 'B', range(180, 191), 8, 'bluetooth'),
        {'B': b},
        [check(90, 'B', status='ghost', truthInsideR95=True),
         check(120, 'B', status='ghost', truthInsideR95=True),
         check(179, 'B', status='ghost', truthInsideR95=True),
         check(180, 'B', recovery='fused', recoveryInsideR95=True)],
        end=190))

    rng = random.Random(4)
    b = path((0, 0), [(40, 1.2, 45)]) + [[60, 400.0, -300.0], [80, 400.0, -300.0]]
    out.append(scenario(
        'teleport-reacquire',
        'B is lost at 40 s and observed 20 s later 500 m away (a car, or a wrong fix upstream): '
        'no blending with the prediction, the track restarts there.',
        observe(rng, b, 'B', range(0, 41), 8, 'bluetooth')
        + [{'t': 60, 'id': 'B', 'observe': {'x': 400.0, 'z': -300.0, 'sigma': 5, 'source': 'gps'}},
           {'t': 61, 'id': 'B', 'observe': {'x': 400.5, 'z': -300.2, 'sigma': 5, 'source': 'gps'}}],
        {'B': b[:41]},
        [check(59, 'B', status='ghost', lastObservedT=40),
         check(60, 'B', recovery='restarted', recoveryInsideR95=False),
         check(62, 'B', status='live', lastObservedT=61)],
        end=62))

    rng = random.Random(5)
    b = path((0, 0), [(60, 1.0, 180)])
    events = observe(rng, b, 'B', range(0, 31), 8, 'bluetooth')
    events += [{'t': 31, 'id': 'B', 'observe': {'x': 99.0, 'z': 99.0, 'sigma': 8, 'source': 'bluetooth', 'age': -10}},
               {'t': 32, 'id': 'B', 'observe': {'x': 98.0, 'z': 98.0, 'sigma': 8, 'source': 'bluetooth', 'age': -2}}]
    out.append(scenario(
        'stale-relay',
        'Late copies of B\'s reports arrive over a relay after newer ones (measured at 21 s and 30 s, '
        'delivered at 31 s and 32 s). They are ignored: nothing moves, the gap counts from 30 s.',
        events, {'B': b},
        [check(33, 'B', lastObservedT=30, truthInsideR95=True),
         check(45, 'B', status='ghost', lastObservedT=30, truthInsideR95=True)],
        end=45))

    rng = random.Random(6)
    b = path((0, 0), [(800, 0.8, 300)])
    out.append(scenario(
        'long-loss',
        'B is lost for 11 minutes. After 10 minutes the prediction stops ("lost": last seen only); '
        'when B is heard again the track starts over.',
        observe(rng, b, 'B', range(0, 31), 8, 'bluetooth') + observe(rng, b, 'B', range(700, 706), 8, 'bluetooth'),
        {'B': b},
        [check(400, 'B', status='ghost', lastObservedT=30, truthInsideR95=True),
         check(640, 'B', status='lost', lastObservedT=30),
         check(700, 'B', recovery='restarted'),
         check(701, 'B', status='live')],
        maxHorizon=600, end=705))

    rng = random.Random(7)
    a = path((0, 0), [(120, 1.4, 0), (100, 1.4, 90)])
    out.append(scenario(
        'dead-reckoning-self',
        'This phone (A) loses GPS at 60 s. Steps and compass (5% long steps, compass 5 degrees off) '
        'carry it on, through a turn east at 120 s. Shown as dead reckoning, still a prediction.',
        observe(rng, a, 'A', range(0, 61), 5, 'gps', noise=3) + hints(rng, a, 'A', range(61, 211), 1.05, 5),
        {'A': a},
        [check(90, 'A', status='ghost', basis='deadReckoned', truthInsideR95=True),
         check(150, 'A', status='ghost', basis='deadReckoned', truthInsideR95=True, r95Max=60),
         check(210, 'A', basis='deadReckoned', truthInsideR95=True, r95Max=90)],
        end=210))

    rng = random.Random(8)
    a = path((10, 10), [(300, 0, 0)])
    out.append(scenario(
        'standing-still',
        'This phone stands still and loses GPS at 30 s; the accelerometer keeps saying "at rest", '
        'so the area stays small instead of growing like a walker\'s.',
        observe(rng, a, 'A', range(0, 31), 5, 'gps', noise=3)
        + [{'t': t, 'id': 'A', 'motion': {'stationary': True}} for t in range(31, 301)],
        {'A': a},
        [check(120, 'A', status='ghost', basis='deadReckoned', truthInsideR95=True, r95Max=40),
         check(300, 'A', status='ghost', truthInsideR95=True, r95Max=40)],
        end=300))

    rng = random.Random(9)
    anchor = path((0, 0), [(200, 0, 0)])
    c = path((10, 5), [(200, 0, 0)])
    b = path((5, 0), [(100, 1.2, 90), (100, 1.2, 270)])
    events = observe(rng, anchor, 'A', range(0, 201), 4, 'gps', noise=2)
    events += observe(rng, c, 'C', range(0, 201), 8, 'bluetooth')
    events += observe(rng, b, 'B', list(range(0, 51)) + list(range(120, 201)), 8, 'bluetooth')
    out.append(scenario(
        'three-phone-demo',
        'A keeps GPS, C stays in Bluetooth range, B walks away east, is out of range from 50 s to '
        '120 s, turns back at 100 s and is heard again on the way back.',
        events, {'A': anchor, 'B': b, 'C': c},
        [check(80, 'A', status='live'),
         check(80, 'C', status='live'),
         check(80, 'B', status='ghost', lastObservedT=50, truthInsideR95=True),
         check(119, 'B', status='ghost', lastObservedT=50, truthInsideR95=True),
         check(120, 'B', recovery='fused'),
         check(121, 'B', status='live', lastObservedT=121)],
        end=200))

    rng = random.Random(11)
    b = path((15, 10), [(40, 0, 90), (96, 1.406, 90), (64, 0, 90), (96, 1.406, 270), (4, 0, 90)])
    out.append(scenario(
        'out-stop-back',
        'Contract scenario S5\'s path with honest Bluetooth positions: B walks east, is lost at 100 s, '
        'stops at 136 s, walks back from 200 s and is heard again at 244 s. Unseen, B reverses; the '
        'area still has to hold B.',
        observe(rng, b, 'B', range(0, 101), 8, 'bluetooth') + observe(rng, b, 'B', range(244, 301), 8, 'bluetooth'),
        {'B': b},
        [check(120, 'B', status='ghost', truthInsideR95=True),
         check(170, 'B', status='ghost', truthInsideR95=True),
         check(220, 'B', status='ghost', truthInsideR95=True),
         check(243, 'B', status='ghost', lastObservedT=100, truthInsideR95=True),
         check(244, 'B', recovery='fused', recoveryInsideR95=True),
         check(246, 'B', status='live')],
        end=300))

    rng = random.Random(10)
    b = path((0, 0), [(60, 1.0, 90)])
    out.append(scenario(
        'clock-skew',
        'B\'s clock runs 1.5 s ahead of ours, so its reports look like they come from the future. '
        'Ages never go negative and B is simply live until it goes quiet.',
        observe(rng, b, 'B', range(0, 13), 8, 'bluetooth', age=1.5),
        {'B': b},
        [check(12, 'B', status='live', lastObservedT=13.5),
         check(25, 'B', status='ghost', lastObservedT=13.5)],
        end=30))
    return out


if __name__ == '__main__':
    for s in build():
        (HERE / f"{s['name']}.json").write_text(json.dumps(s, indent=1) + '\n')
        print(s['name'], len(s['events']), 'events', len(s['checks']), 'checks')
