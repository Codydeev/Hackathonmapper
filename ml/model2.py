"""Movement model v2: the walking history of v1, plus what the phone knows
about the surroundings and the plan.

Extra inputs:
  map    a 48 x 48 patch of the area's map image (paths, roads, water), 10 m
         per pixel, rotated so the walking direction points up and centred
         80 m ahead of the person. Rows run from far ahead to behind, columns
         from left to right. A small convolutional network reads it.
  dest   the place the person planned to go, if the phone knows one:
         direction (in the walking frame) and log distance.
  flags  whether a map and a destination are available, so the same model
         also works without them (indoors, or before the map is loaded).
"""

import math

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

import model as M

PATCH = 48
PATCH_RES = 10.0
PATCH_AHEAD = 80.0
DEST_FAR = 5000.0
N_EXTRA = 5                     # destination (4) + map available (1)
N_IN2 = M.N_IN + N_EXTRA
EMB = 64


def patch_offsets():
    """(P, P, 2) points the patch pixels look at, in the walking frame
    (x forward, y left), relative to the person."""
    k = np.arange(PATCH) + 0.5
    ahead = PATCH_AHEAD + (PATCH / 2 - k) * PATCH_RES   # row 0 is farthest ahead
    left = (PATCH / 2 - k) * PATCH_RES                  # column 0 is leftmost
    U, V = np.meshgrid(ahead, left, indexing='ij')
    return np.stack([U, V], -1)


def dest_features(dest, has):
    """dest (B, 2) in the walking frame relative to the person, has (B,) bool."""
    d = np.maximum(np.linalg.norm(dest, axis=1), 1e-6)
    f = np.stack([dest[:, 0] / d, dest[:, 1] / d, np.log1p(d) / math.log1p(DEST_FAR), np.ones(len(d))], 1)
    f[~has] = 0
    return f.astype(np.float32)


def sample_map(raster, meta, pts):
    """Bilinear look-up of a (3, H, W) float map at metre points (n, P, P, 2).
    Pixel centres sit at xMin + (col + 0.5) * res; outside the image is 0."""
    n = len(pts)
    gx = (pts[..., 0] - meta['xMin']) / meta['res'] / meta['width'] * 2 - 1
    gy = (meta['yMax'] - pts[..., 1]) / meta['res'] / meta['height'] * 2 - 1
    grid = torch.as_tensor(np.stack([gx, gy], -1), dtype=torch.float32).reshape(1, n * PATCH, PATCH, 2)
    out = F.grid_sample(raster[None], grid, mode='bilinear', padding_mode='zeros', align_corners=False)
    return out.reshape(3, n, PATCH, PATCH).permute(1, 0, 2, 3)


class MovementModel2(nn.Module):
    def __init__(self):
        super().__init__()
        self.cnn = nn.Sequential(
            nn.Conv2d(3, 8, 5, 2, 2), nn.SiLU(),     # 48 -> 24
            nn.Conv2d(8, 16, 3, 2, 1), nn.SiLU(),    # 24 -> 12
            nn.Conv2d(16, 32, 3, 2, 1), nn.SiLU(),   # 12 -> 6
            nn.Conv2d(32, 32, 3, 2, 1), nn.SiLU(),   # 6 -> 3
            nn.Flatten(), nn.Linear(32 * 3 * 3, EMB), nn.SiLU(),
        )
        self.net = nn.Sequential(
            nn.Linear(N_IN2 + EMB, M.HIDDEN), nn.SiLU(),
            nn.Linear(M.HIDDEN, M.HIDDEN), nn.SiLU(),
            nn.Linear(M.HIDDEN, M.HIDDEN), nn.SiLU(),
            nn.Linear(M.HIDDEN, M.K * 6),
        )

    def embed(self, patch, has_map):
        """The map part depends only on where the person is, not on h, so a
        phone computes it once when the link drops."""
        return self.cnn(patch) * has_map[:, None]

    def head(self, x, emb, h):
        p = self.net(torch.cat([x, emb], 1)).view(-1, M.K, 6)
        s = M.horizon_scale(h)[:, None, None]
        logw = torch.log_softmax(p[..., 0], -1)
        mean = p[..., 1:3] * s
        std = M.STD_FLOOR + torch.exp(p[..., 3:5].clamp(-7, 3)) * s
        rho = 0.95 * torch.tanh(p[..., 5])
        return logw, mean, std, rho

    def forward(self, x, patch, h):
        return self.head(x, self.embed(patch, x[:, -1]), h)
