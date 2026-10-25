"""Data for live/map.html: the trained models on a real map of Hervanta.

    python ml/live/export_map.py [radio_run_dir]    # -> ml/live/map-data.json

radio   held-out Hervanta moments with simulated nearby phones and readings,
        the GPU-trained network's fix, the hybrid fix and where the person
        really was (lat/lon)
walks   the route demo's walks (60 s before, 10 min after, in the map's metre
        frame); the page runs the route model on them itself
sim     every non-overlapping 10 min stretch of the held-out Hervanta walks
        (fold 1): 60 s of GPS, then the true path for 10 min after GPS is lost

Also copies the Hervanta graph whose popularity comes from the other fold of
days (fold 0) to export/graphs/, so the page never uses counts that include
the walks it shows.
"""

import json
import shutil
import sys
from pathlib import Path

import numpy as np
import torch

HERE = Path(__file__).parent
ML = HERE.parent
sys.path.insert(0, str(ML))
sys.path.insert(0, str(ML / 'demo'))

import train_radio as TR  # noqa: E402
from build_routes import pick_walks  # noqa: E402
from geo import origin, to_latlon  # noqa: E402
from radio_sim import simulate  # noqa: E402

AREA = 'hervanta'
EXAMPLES = {
    'UWB, 4 phones nearby (RTK)': 4,
    'UWB + steps, 2 phones nearby (RTK)': 3,
    'UWB, 4 phones nearby (GPS)': 3,
    'Bluetooth, 4 phones nearby (GPS)': 3,
    'Bluetooth, 1 phone nearby (GPS)': 2,
}


def ll(x, y):
    lat, lon = to_latlon(np.asarray(x, float), np.asarray(y, float), AREA)
    return np.stack([np.round(lat, 7), np.round(lon, 7)], -1).tolist()


@torch.no_grad()
def radio_examples(run):
    net = TR.RadioNet().to(TR.DEV)
    net.load_state_dict(torch.load(run / 'model.pt', map_location=TR.DEV))
    net.eval()
    test = TR.walk_windows([AREA], 15)
    rng = np.random.default_rng(11)
    out = []
    for k, (name, n) in enumerate(EXAMPLES.items()):
        cfg = TR.SCENARIOS[name]
        idx = torch.as_tensor(rng.choice(len(test), 64, replace=False))
        walks = test[idx].to(TR.DEV)
        g = torch.Generator(device=TR.DEV).manual_seed(77 + k)
        tok, mask, target, ref, extra = simulate(walks, g, cfg)
        mean, sigma = net(*TR.thin(tok, mask))
        hybrid = TR.refine(extra, mean + ref) - ref
        err_n = torch.linalg.norm(mean - target, dim=1)
        # A typical spread of cases: evenly spaced through the errors, not cherry-picked.
        order = torch.argsort(err_n).cpu().numpy()
        picks = order[np.linspace(0, len(order) - 1, n + 2)[1:-1].astype(int)]
        for i in picks:
            now = walks[i, -1].cpu().numpy()                     # person now, map frame
            walk = walks[i].cpu().numpy()
            T = extra['reported'].shape[2]
            phones = []
            for a in range(4):
                if not bool(extra['present'][i, a]):
                    continue
                rep = extra['reported'][i, a, -1].cpu().numpy() + now
                tru = extra['anchor'][i, a, -1].cpu().numpy() + now
                uwb = float(extra['uwb'][i, a, -1]) if bool(extra['uwb_ok'][i, a, -1]) else None
                ble = float(extra['rssi'][i, a, -1]) if bool(extra['ble_ok'][i, a, -1]) else None
                phones.append({'reported': ll(*rep), 'true': ll(*tru), 'uwb': uwb, 'rssi': ble,
                               'bleDistance': None if ble is None else 10 ** ((-59 - ble) / 25)})
            est = (mean[i] - target[i]).cpu().numpy() + now
            hyb = (hybrid[i] - target[i]).cpu().numpy() + now
            out.append({'scenario': name, 'track': ll(walk[:, 0], walk[:, 1]), 'truth': ll(*now),
                        'network': ll(*est), 'networkSigma': float(sigma[i]), 'hybrid': ll(*hyb),
                        'errNetwork': float(err_n[i]), 'errHybrid': float(torch.linalg.norm(hybrid[i] - target[i])),
                        'steps': bool(cfg.get('steps')), 'rtk': bool(cfg.get('rtk')), 'phones': phones,
                        'gpsSigma': float(extra['gps_sigma'][i])})
    return out


def sim_walks():
    """Held-out windows start every 30 s along each walk; keep every 20th of a
    continuous run, so the 10 min stretches never overlap."""
    windows = json.loads((ML / 'data' / 'eval' / 'hervanta-windows.json').read_text())
    out, prev, k = [], None, 0
    for w in windows:
        if w['fold'] != 1:
            continue
        p = np.array(w['path'])
        cont = prev is not None and prev['day'] == w['day'] and np.hypot(*(np.array(prev['path'][30]) - p[0])) < 1
        k = k + 1 if cont else 0
        prev = w
        if k % 20 == 0:
            out.append({'hist': np.round(w['hist'], 1).tolist(), 'path': np.round(p, 1).tolist(), 'day': w['day']})
    return out


def main():
    run = Path(sys.argv[1]) if len(sys.argv) > 1 else sorted((ML / 'runs').glob('radio-*'))[-1]
    lat0, lon0 = origin(AREA)
    data = {'area': AREA, 'lat0': lat0, 'lon0': lon0, 'radioRun': run.name, 'radio': radio_examples(run), 'walks': pick_walks(),
            'sim': sim_walks()}
    (HERE / 'map-data.json').write_text(json.dumps(data, separators=(',', ':')))
    shutil.copyfile(ML / 'data' / 'eval' / f'{AREA}-pop-from-fold0.json', ML / 'export' / 'graphs' / f'{AREA}-pop-from-fold0.json')
    print(f'wrote map-data.json: {len(data["radio"])} radio examples from {run.name}, {len(data["walks"])} walks, '
          f'{len(data["sim"])} simulation walks; copied the fold-0 popularity graph')


if __name__ == '__main__':
    main()
