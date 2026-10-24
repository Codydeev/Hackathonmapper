// Wire types for the simulated field map (server → browser only). These are not part of the
// gateway upload contract: towers and other infrastructure anchors exist only in simulation.

export type FieldAnchorKind = 'cell-tower' | 'wifi-ap' | 'ble-beacon' | 'anchor-phone';

export const FIELD_ANCHOR_LABELS: Record<FieldAnchorKind, string> = {
  'cell-tower': 'Cell tower',
  'wifi-ap': 'Wi-Fi access point',
  'ble-beacon': 'BLE beacon',
  'anchor-phone': 'Anchor phone',
};

/** Map coordinates are the shared frame's floor plane: x east, z north, meters. */
export interface MapPoint {
  x: number;
  z: number;
}

export interface FieldAnchor {
  id: string;
  label: string;
  kind: FieldAnchorKind;
  position: MapPoint;
  /** Simulated usable range for positioning fixes. */
  rangeMeters: number;
}

export interface FieldPhone {
  id: string;
  label: string;
  role: 'mobile' | 'gateway';
  position: MapPoint;
  /** Simulated estimate; null when no anchor is in range and there is no fix. */
  accuracyMeters: number | null;
  /** Anchors this phone is currently using for its simulated position fix. */
  anchorsInRange: string[];
  trail: MapPoint[];
}

export interface FieldLink {
  a: string;
  b: string;
  rssi: number;
}

export interface MapSnapshot {
  serverTime: number;
  /** True only while the dashboard is in simulated mode. */
  active: boolean;
  running: boolean;
  elapsedSeconds: number;
  name: string;
  bounds: { minX: number; maxX: number; minZ: number; maxZ: number };
  anchors: FieldAnchor[];
  phones: FieldPhone[];
  /** Simulated direct BLE links between phones (including anchor phones). */
  links: FieldLink[];
}
