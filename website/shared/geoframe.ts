// Frames anchored to a GPS origin. Mirrors `GeoFrame.origins` in ios/MeshCore (Models.swift):
// keep the two tables identical. +z points along the origin's bearing (north by default, so
// x east and z north); a frame without an origin is a room frame of its own (x right, z forward).

export interface GeoOrigin {
  latitude: number;
  longitude: number;
  /** Compass bearing of +z, degrees clockwise from north. */
  bearingDegrees: number;
}

export const GEO_FRAMES: Readonly<Record<string, GeoOrigin>> = {
  // Tietotalo, Tampere University Hervanta campus.
  'hervanta-v1': { latitude: 61.4499, longitude: 23.856, bearingDegrees: 0 },
};

const METERS_PER_DEGREE = (6_371_008.8 * Math.PI) / 180;

export const geoOrigin = (frameId: string | null): GeoOrigin | null =>
  frameId ? GEO_FRAMES[frameId] ?? null : null;

/** Frame floor coordinates to latitude/longitude (the app's `GeoFrame.unproject`). */
export function toLatLon(origin: GeoOrigin, x: number, z: number): { latitude: number; longitude: number } {
  const bearing = (origin.bearingDegrees * Math.PI) / 180;
  const east = x * Math.cos(bearing) + z * Math.sin(bearing);
  const north = -x * Math.sin(bearing) + z * Math.cos(bearing);
  return {
    latitude: origin.latitude + north / METERS_PER_DEGREE,
    longitude: origin.longitude + east / (METERS_PER_DEGREE * Math.cos((origin.latitude * Math.PI) / 180)),
  };
}

/** Latitude/longitude to frame floor coordinates (the app's `GeoFrame.project`). */
export function toFrame(origin: GeoOrigin, latitude: number, longitude: number): { x: number; z: number } {
  const east = (longitude - origin.longitude) * METERS_PER_DEGREE * Math.cos((origin.latitude * Math.PI) / 180);
  const north = (latitude - origin.latitude) * METERS_PER_DEGREE;
  const bearing = (origin.bearingDegrees * Math.PI) / 180;
  return {
    x: east * Math.cos(bearing) - north * Math.sin(bearing),
    z: east * Math.sin(bearing) + north * Math.cos(bearing),
  };
}

/** Axis names for the 3D view: compass directions for north-up GPS frames, else x/z. */
export function axisNames(origin: GeoOrigin | null): { x: string; z: string } {
  if (!origin) return { x: 'X', z: 'Z' };
  if (origin.bearingDegrees === 0) return { x: 'E', z: 'N' };
  return { x: 'X', z: `Z ${Math.round(origin.bearingDegrees)}°` };
}

/**
 * A phone's frame coordinates as text: "12.3 m E · 4.5 m N" in north-up GPS frames (negative
 * values as W / S), "x 12.3 · z 4.5 m" otherwise.
 */
export function coordinateText(origin: GeoOrigin | null, x: number, z: number): string {
  if (origin && origin.bearingDegrees === 0) {
    const ew = `${Math.abs(x).toFixed(1)} m ${x < 0 ? 'W' : 'E'}`;
    const ns = `${Math.abs(z).toFixed(1)} m ${z < 0 ? 'S' : 'N'}`;
    return `${ew} · ${ns}`;
  }
  return `x ${x.toFixed(1)} · z ${z.toFixed(1)} m`;
}

export function latLonText(origin: GeoOrigin | null, x: number, z: number): string | null {
  if (!origin) return null;
  const { latitude, longitude } = toLatLon(origin, x, z);
  return `${Math.abs(latitude).toFixed(6)}° ${latitude < 0 ? 'S' : 'N'}, ${Math.abs(longitude).toFixed(6)}° ${longitude < 0 ? 'W' : 'E'}`;
}
