"""Simulated Bluetooth and UWB between a walking person and nearby phones,
vectorised in PyTorch so training data can be made on the GPU.

Nothing here is measured: every number below is an assumption from typical
values for phones outdoors, to be replaced by real logs (see ml/README.md).

A sample is a 31 s window of a real walk (positions every second, the last
one is "now") plus 1-4 nearby phones ("anchors") that are standing or
walking 5-40 m away and report their own position (phone GPS, or RTK).
Each second, each anchor may get:
  Bluetooth  RSSI = p0 - 10 n log10(d) + slow shadowing + fast noise
             - body loss when someone is in the way; heard with a
             probability that falls off with distance
  UWB        time-of-flight range: d + 8 cm noise, plus a positive bias when
             the path is blocked (non-line-of-sight), dropouts, and a
             maximum range
The lost phone may also have its own pedometer track (step length and
compass errors), giving how far it moved between each second and now.
"""

import math

import torch

WINDOW = 31


_AR = {}


def ar1(shape, rho, sigma, steps, g, device):
    """AR(1) noise along the last axis, stationary std sigma (broadcastable),
    as one matrix product: e_t = sum_s rho^(t-s) c_s eps_s."""
    key = (rho, steps, str(device))
    if key not in _AR:
        t = torch.arange(steps, device=device)
        lag = (t[:, None] - t[None]).float()
        c = torch.full((steps,), math.sqrt(1 - rho * rho), device=device)
        c[0] = 1.0
        _AR[key] = torch.where(lag >= 0, rho ** lag.clamp(min=0), torch.zeros_like(lag)) * c[None]
    out = torch.randn(*shape, steps, device=device, generator=g) @ _AR[key].T
    return out * sigma.unsqueeze(-1) if torch.is_tensor(sigma) else out * sigma


def simulate(walks, g, cfg=None):
    """walks: (B, 31, 2) true positions of the lost person, metres.
    cfg: overrides for evaluation, e.g. {'anchors': 2, 'ble': True, 'uwb': False,
    'rtk': True, 'steps': False}. Returns (tokens (B, 31*4, F), mask (B, 31*4), target (B, 2), ref (B, 2))."""
    cfg = cfg or {}
    dev = walks.device
    B, T, K = walks.shape[0], WINDOW, 4
    U = lambda lo, hi, *s: lo + (hi - lo) * torch.rand(*s, device=dev, generator=g)
    walk = walks - walks[:, -1:]                                       # now at the origin
    n_anchor = torch.full((B,), cfg['anchors'], device=dev) if 'anchors' in cfg else torch.randint(1, K + 1, (B,), device=dev, generator=g)
    present = torch.arange(K, device=dev)[None] < n_anchor[:, None]    # (B, K)

    # Anchors: phones 5-30 m from the person now, standing or walking straight.
    r0, a0 = U(5, 30, B, K), U(0, 2 * math.pi, B, K)
    now = torch.stack([r0 * torch.cos(a0), r0 * torch.sin(a0)], -1)              # person is at the origin now
    moving = torch.rand(B, K, device=dev, generator=g) < 0.5
    speed, head = U(0.3, 1.5, B, K) * moving, U(0, 2 * math.pi, B, K)
    t = torch.arange(T, device=dev).float() - (T - 1)                           # seconds before now (<= 0)
    anchor = now[:, :, None] + torch.stack([(speed * torch.cos(head))[..., None] * t, (speed * torch.sin(head))[..., None] * t], -1)
    t = t + (T - 1)
    # What the anchors report about themselves: phone GPS (2-6 m, slowly drifting) or RTK (3 cm).
    rtk = torch.full((B,), bool(cfg['rtk']), device=dev) if 'rtk' in cfg else torch.rand(B, device=dev, generator=g) < 0.3
    gps_sigma = torch.where(rtk, torch.full((B,), 0.03, device=dev), U(2, 6, B))
    err = torch.stack([ar1((B, K), 0.97, gps_sigma[:, None], T, g, dev) for _ in range(2)], -1)
    reported = anchor + err

    d = torch.linalg.norm(walk[:, None] - anchor, dim=-1).clamp(min=0.3)      # (B, K, T)
    blocked_p = torch.rand(B, K, device=dev, generator=g) < 0.3
    flip = torch.rand(B, K, T, device=dev, generator=g) < 0.05                 # someone steps in or out of the way
    blocked = (blocked_p[..., None] ^ (torch.cumsum(flip.int(), -1) % 2 == 1)).float()

    # Bluetooth.
    has_ble = torch.full((B,), bool(cfg['ble']), device=dev) if 'ble' in cfg else torch.rand(B, device=dev, generator=g) < 0.8
    p0, n = -59 + 3 * torch.randn(B, K, device=dev, generator=g), U(2.0, 3.0, B, K)
    shadow = ar1((B, K), 0.9, U(2, 6, B, K), T, g, dev)
    rssi = p0[..., None] - 10 * n[..., None] * torch.log10(d) + shadow + 2 * torch.randn(B, K, T, device=dev, generator=g) - 8 * blocked
    heard = torch.rand(B, K, T, device=dev, generator=g) < torch.sigmoid(-(d - U(40, 80, B, K)[..., None]) / 8)
    ble_ok = heard & has_ble[:, None, None] & present[..., None]

    # UWB.
    has_uwb = torch.full((B,), bool(cfg['uwb']), device=dev) if 'uwb' in cfg else torch.rand(B, device=dev, generator=g) < 0.6
    if 'ble' not in cfg and 'uwb' not in cfg:
        has_ble = has_ble | ~has_uwb      # every training sample has at least one radio
        ble_ok = heard & has_ble[:, None, None] & present[..., None]
    max_r = U(20, 50, B, K)[..., None]
    drop = torch.rand(B, K, T, device=dev, generator=g) < (0.1 + 0.4 * blocked)
    nlos = torch.rand(B, K, T, device=dev, generator=g) < (0.15 + 0.5 * blocked)
    bias = -torch.log(torch.rand(B, K, T, device=dev, generator=g).clamp(min=1e-6)) * U(0.3, 1.2, B, K)[..., None]
    uwb = d + 0.08 * torch.randn(B, K, T, device=dev, generator=g) + nlos * bias
    uwb_ok = (d < max_r) & ~drop & has_uwb[:, None, None] & present[..., None]

    # The lost phone's own pedometer: how far it moved from second t to now, as it measured it.
    has_steps = torch.full((B,), bool(cfg['steps']), device=dev) if 'steps' in cfg else torch.rand(B, device=dev, generator=g) < 0.5
    step = torch.diff(walk, dim=1)                                                 # (B, T-1, 2)
    bias_h = (8 * math.pi / 180) * torch.randn(B, device=dev, generator=g)[:, None] \
        + torch.cumsum((0.2 * math.pi / 180) * torch.randn(B, T - 1, device=dev, generator=g), 1)
    scale = 1 + 0.07 * torch.randn(B, 1, device=dev, generator=g)
    c, s = torch.cos(bias_h), torch.sin(bias_h)
    meas = scale[..., None] * torch.stack([c * step[..., 0] - s * step[..., 1], s * step[..., 0] + c * step[..., 1]], -1) \
        + 0.1 * torch.randn(B, T - 1, 2, device=dev, generator=g)
    meas = meas * (torch.linalg.norm(step, dim=-1, keepdim=True) >= 0.25)
    to_now = torch.flip(torch.cumsum(torch.flip(meas, [1]), 1), [1])               # displacement from second t to now
    to_now = torch.cat([to_now, torch.zeros(B, 1, 2, device=dev)], 1) * has_steps[:, None, None]

    # Tokens: one per (second, anchor) with any reading, relative to the anchors' mean reported position now.
    w = present.float()
    ref = (reported[:, :, -1] * w[..., None]).sum(1) / w.sum(1, keepdim=True)
    rel = (reported - ref[:, None, None]) / 50
    tt = ((t - (T - 1)) / 30).expand(B, K, T)
    feat = torch.stack([
        rel[..., 0], rel[..., 1],
        ble_ok.float(), torch.where(ble_ok, (rssi + 70) / 15, torch.zeros_like(rssi)),
        uwb_ok.float(), torch.where(uwb_ok, uwb / 40, torch.zeros_like(uwb)),
        (torch.log(gps_sigma) / 3)[:, None, None].expand(B, K, T),
        tt, has_steps.float()[:, None, None].expand(B, K, T),
        (to_now[..., 0] / 50)[:, None].expand(B, K, T), (to_now[..., 1] / 50)[:, None].expand(B, K, T),
    ], -1)                                                                          # (B, K, T, F)
    mask = ble_ok | uwb_ok
    target = -ref                                                                   # person is at the origin
    return feat.reshape(B, K * T, -1), mask.reshape(B, K * T), target, ref, {
        'reported': reported, 'uwb': uwb, 'uwb_ok': uwb_ok, 'rssi': rssi, 'ble_ok': ble_ok, 'to_now': to_now, 'gps_sigma': gps_sigma,
        'anchor': anchor, 'present': present}


N_FEAT = 11
