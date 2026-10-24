"""The movement model: given where a person was over the last 60 s, where are
they likely to be h seconds from now? Shared by training, evaluation and the
exporters, so the phone and web versions compute exactly the same features.

Input (all positions in metres, any flat frame such as east/north):
  hist  31 positions, 2 s apart, oldest first. The last one is "now". If less
        history exists, repeat the oldest known position (a person who was
        standing still).
  acc   how far off those positions may be, in metres (accuracyMeters). Use
        about 5 for a GPS phone and the mesh's estimate for a lost phone.
  h     seconds ahead to predict, 2..180.

Output: a mixture of K 2D Gaussians for the displacement from "now", in a
frame rotated so +x is the direction the person was walking.
"""

import math

import numpy as np
import torch
import torch.nn as nn

K = 6
HIST_N = 31
HIST_STEP = 2
H_MIN, H_MAX = 2, 180
N_IN = 2 * (HIST_N - 1) + 4
HIDDEN = 128
HEADING_LOOKBACK = (5, 15, 30)   # steps back (10, 30, 60 s) to find a direction
HEADING_MIN = 3.0                # m moved before a direction counts
POS_SCALE = 50.0
STD_FLOOR = 0.5


def heading(hist):
    """Walking direction from the history (B, 31, 2) relative to now."""
    th = np.zeros(len(hist))
    has = np.zeros(len(hist), bool)
    for k in HEADING_LOOKBACK:
        v = hist[:, -1] - hist[:, -1 - k]
        pick = ~has & (np.linalg.norm(v, axis=1) >= HEADING_MIN)
        th[pick] = np.arctan2(v[pick, 1], v[pick, 0])
        has |= pick
    return th, has


def rotate(xy, th):
    c, s = np.cos(th), np.sin(th)
    while c.ndim < xy.ndim - 1:
        c, s = c[..., None], s[..., None]
    return np.stack([c * xy[..., 0] - s * xy[..., 1], s * xy[..., 0] + c * xy[..., 1]], -1)


def features(hist, acc, h):
    """hist (B, 31, 2) in any frame, acc (B,), h (B,) -> (B, N_IN), heading (B,)."""
    hist = hist - hist[:, -1:]
    th, has = heading(hist)
    r = rotate(hist[:, :-1], -th) / POS_SCALE
    extra = np.stack([np.log(h) / math.log(H_MAX), np.sqrt(h / H_MAX), acc / 20.0, has.astype(float)], 1)
    return np.concatenate([r.reshape(len(hist), -1), extra], 1).astype(np.float32), th


def horizon_scale(h):
    return 2.0 + 1.3 * h   # metres a brisk walker covers in h seconds, plus a little


class MovementModel(nn.Module):
    def __init__(self):
        super().__init__()
        self.net = nn.Sequential(
            nn.Linear(N_IN, HIDDEN), nn.SiLU(),
            nn.Linear(HIDDEN, HIDDEN), nn.SiLU(),
            nn.Linear(HIDDEN, HIDDEN), nn.SiLU(),
            nn.Linear(HIDDEN, K * 6),
        )

    def forward(self, x, h):
        """-> log weights (B, K), means (B, K, 2), stds (B, K, 2), rho (B, K)."""
        p = self.net(x).view(-1, K, 6)
        s = horizon_scale(h)[:, None, None]
        logw = torch.log_softmax(p[..., 0], -1)
        mean = p[..., 1:3] * s
        std = STD_FLOOR + torch.exp(p[..., 3:5].clamp(-7, 3)) * s
        rho = 0.95 * torch.tanh(p[..., 5])
        return logw, mean, std, rho


def mixture_logpdf(y, logw, mean, std, rho):
    """log p(y) for y (B, 2) or (B, S, 2) under the mixture."""
    if y.dim() == 2:
        y = y[:, None]
    d = (y[:, :, None, :] - mean[:, None]) / std[:, None]
    r = rho[:, None]
    q = (d[..., 0] ** 2 - 2 * r * d[..., 0] * d[..., 1] + d[..., 1] ** 2) / (1 - r ** 2)
    logn = -q / 2 - torch.log(2 * math.pi * std[:, None, :, 0] * std[:, None, :, 1] * torch.sqrt(1 - r ** 2))
    return torch.logsumexp(logw[:, None] + logn, -1)


def mixture_sample(n, logw, mean, std, rho, gen=None):
    """(B, n, 2) samples from each mixture."""
    B = logw.shape[0]
    comp = torch.multinomial(logw.exp(), n, replacement=True, generator=gen)
    pick = lambda t: torch.gather(t, 1, comp.view(B, n, *([1] * (t.dim() - 2))).expand(B, n, *t.shape[2:]))
    m, s, r = pick(mean), pick(std), pick(rho)
    z = torch.randn(B, n, 2, generator=gen)
    x = z[..., 0]
    y = r * z[..., 0] + torch.sqrt(1 - r ** 2) * z[..., 1]
    return m + s * torch.stack([x, y], -1)


def mixture_mean(logw, mean):
    return (logw.exp()[..., None] * mean).sum(1)
