"""One flat metre frame per area, shared by the GPS tracks and the map, so a
track and the paths under it line up exactly. x is east, y is north, from the
centre of the area's box."""

import math

import numpy as np

from fetch_osm import AREAS

R_EARTH = 6371000.0
MAP_RES = 8.0                     # metres per map pixel
PAD_LAT, PAD_LON = 0.006, 0.012   # the map reaches this far beyond the track box


def origin(area):
    w, s, e, n = AREAS[area]
    return (s + n) / 2, (w + e) / 2


def to_xy(lat, lon, area):
    lat0, lon0 = origin(area)
    lat, lon = np.asarray(lat, float), np.asarray(lon, float)
    return np.stack([R_EARTH * math.cos(math.radians(lat0)) * np.radians(lon - lon0),
                     R_EARTH * np.radians(lat - lat0)], -1)


def to_latlon(x, y, area):
    lat0, lon0 = origin(area)
    return lat0 + np.degrees(np.asarray(y) / R_EARTH), lon0 + np.degrees(np.asarray(x) / (R_EARTH * math.cos(math.radians(lat0))))


def map_extent(area):
    """x_min, y_max, width, height (pixels) of the area's map image."""
    w, s, e, n = AREAS[area]
    (x0, y0), (x1, y1) = to_xy([s - PAD_LAT, n + PAD_LAT], [w - PAD_LON, e + PAD_LON], area)
    return x0, y1, int(math.ceil((x1 - x0) / MAP_RES)), int(math.ceil((y1 - y0) / MAP_RES))
