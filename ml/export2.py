"""Export movement model v2 (map + destination) for the phone and the web.

    python ml/export2.py [run_dir]     # default ml/runs/v2-latest

Writes to ml/export/:
  movement-model-v2.json   weights + constants for the JS and Swift runtimes
  maps/hervanta.png        the map image the model reads (R paths, G roads,
  maps/hervanta.json       B water) and its frame (lat0/lon0, xMin, yMax, res)
  golden-v2.json           test cases on the Hervanta map, predicted by PyTorch
"""

import json
import shutil
import sys
from pathlib import Path

import numpy as np
import torch

import model as M
import model2 as M2
from export import spec as spec_v1
from train import TEST_AREA
from train2 import DATA, load_maps

HERE = Path(__file__).parent
OUT = HERE / 'export'


def spec(net):
    r = lambda a: np.round(a.detach().numpy().astype(float), 6).tolist()
    s = spec_v1(net)
    convs = [m for m in net.cnn if isinstance(m, torch.nn.Conv2d)]
    fc = [m for m in net.cnn if isinstance(m, torch.nn.Linear)][0]
    s.update({
        'version': 2,
        'patch': {'size': M2.PATCH, 'res': M2.PATCH_RES, 'ahead': M2.PATCH_AHEAD},
        'destFar': M2.DEST_FAR,
        'cnn': [{'w': r(c.weight), 'b': r(c.bias), 'stride': c.stride[0], 'pad': c.padding[0]} for c in convs],
        'cnnFc': {'w': r(fc.weight), 'b': r(fc.bias)},
    })
    return s


@torch.no_grad()
def predict_world(net, raster, meta, hist, acc, h, dest):
    """Mixture in the map frame for absolute histories `hist` (B, 31, 2)."""
    x, th = M.features(hist, acc, h)
    now = hist[:, -1]
    has_dest = ~np.isnan(dest[:, 0])
    dfeat = M2.dest_features(M.rotate(np.nan_to_num(dest) - now, -th), has_dest)
    pts = now[:, None, None] + M.rotate(M2.patch_offsets()[None], th)
    patch = M2.sample_map(raster, meta, pts)
    x2 = np.concatenate([x, dfeat, np.ones((len(x), 1), np.float32)], 1)
    logw, mean, std, rho = net(torch.as_tensor(x2), patch, torch.as_tensor(h, dtype=torch.float32))
    w, mean, std, rho = logw.exp().numpy(), mean.numpy(), std.numpy(), rho.numpy()
    c, s = np.cos(th)[:, None], np.sin(th)[:, None]
    mw = np.stack([c * mean[..., 0] - s * mean[..., 1], s * mean[..., 0] + c * mean[..., 1]], -1) + now[:, None]
    sxx, syy, sxy = std[..., 0] ** 2, std[..., 1] ** 2, rho * std[..., 0] * std[..., 1]
    cov = np.stack([c * c * sxx - 2 * c * s * sxy + s * s * syy,
                    c * s * (sxx - syy) + (c * c - s * s) * sxy,
                    s * s * sxx + 2 * c * s * sxy + c * c * syy], -1)
    return w, mw, cov, patch.sum((1, 2, 3)).numpy()


def main():
    run = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / 'runs' / 'v2-latest'
    net = M2.MovementModel2()
    net.load_state_dict(torch.load(run / 'model.pt'))
    net.eval()
    (OUT / 'maps').mkdir(parents=True, exist_ok=True)
    (OUT / 'movement-model-v2.json').write_text(json.dumps(spec(net), separators=(',', ':')))
    shutil.copy(DATA / 'map' / f'{TEST_AREA}.png', OUT / 'maps' / f'{TEST_AREA}.png')
    shutil.copy(DATA / 'map' / f'{TEST_AREA}.meta.json', OUT / 'maps' / f'{TEST_AREA}.json')

    raster, meta = load_maps()[TEST_AREA]
    z = np.load(DATA / 'windows' / f'{TEST_AREA}.npz')
    rng = np.random.default_rng(7)
    i = rng.choice(len(z['hist']), 24, replace=False)
    hist = np.round(z['hist'][i].astype(float) + z['origin'][i, None].astype(float), 3)
    hist[0] = hist[0, -1]                       # standing still
    hist[1, :20] = hist[1, 20]                  # short history
    dest = z['dest'][i].astype(float) + z['origin'][i].astype(float)
    dest[::2] = np.nan                          # half without a destination
    dest = np.round(dest, 3)
    acc = rng.choice([4.0, 8.0, 15.0, 25.0], len(i))
    h = rng.choice([2.0, 10.0, 30.0, 60.0, 120.0, 180.0, 45.5], len(i))
    w, m, cov, psum = predict_world(net, raster, meta, hist, acc, h, dest)
    cases = [{'hist': hist[k].tolist(), 'acc': float(acc[k]), 'h': float(h[k]),
              'destination': None if np.isnan(dest[k, 0]) else dest[k].tolist(),
              'patchSum': float(psum[k]), 'weights': w[k].tolist(), 'means': m[k].tolist(), 'covs': cov[k].tolist()}
             for k in range(len(i))]
    (OUT / 'golden-v2.json').write_text(json.dumps(cases))
    kb = (OUT / 'movement-model-v2.json').stat().st_size / 1024
    params = sum(p.numel() for p in net.parameters())
    print(f'exported {run.resolve().name}: {params} parameters, movement-model-v2.json {kb:.0f} kB, '
          f'map {(OUT / "maps" / f"{TEST_AREA}.png").stat().st_size / 1024:.0f} kB, {len(cases)} golden cases')


if __name__ == '__main__':
    main()
