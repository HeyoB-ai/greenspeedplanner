// ── Zuivere geo- en statistiekhelpers (geen Supabase, los testbaar) ─────────

export interface LatLng { lat: number; lng: number; }

const EARTH_RADIUS_M = 6_371_000;
const toRad = (deg: number) => (deg * Math.PI) / 180;

// Hemelsbrede afstand (Haversine) in meters.
export function haversineMeters(a: LatLng, b: LatLng): number {
  const dLat = toRad(b.lat - a.lat);
  const dLng = toRad(b.lng - a.lng);
  const lat1 = toRad(a.lat);
  const lat2 = toRad(b.lat);
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_RADIUS_M * Math.asin(Math.min(1, Math.sqrt(h)));
}

export interface Regression {
  slope: number;      // seconden per meter
  intercept: number;  // seconden (overdrachtstijd aan de deur)
  r2: number;         // verklaarde variantie, 0..1
  n: number;
}

// Eenvoudige lineaire regressie van y op x (kleinste kwadraten).
// null als er te weinig spreiding is om een helling te bepalen.
export function linearRegression(points: { x: number; y: number }[]): Regression | null {
  const n = points.length;
  if (n < 2) return null;

  let sx = 0, sy = 0, sxx = 0, sxy = 0, syy = 0;
  for (const p of points) {
    sx += p.x; sy += p.y; sxx += p.x * p.x; sxy += p.x * p.y; syy += p.y * p.y;
  }
  const denom = n * sxx - sx * sx;
  if (denom === 0) return null; // alle x gelijk → geen helling bepaalbaar

  const slope = (n * sxy - sx * sy) / denom;
  const intercept = (sy - slope * sx) / n;

  // R² bepalen.
  const meanY = sy / n;
  let ssTot = 0, ssRes = 0;
  for (const p of points) {
    const pred = intercept + slope * p.x;
    ssTot += (p.y - meanY) ** 2;
    ssRes += (p.y - pred) ** 2;
  }
  const r2 = ssTot === 0 ? 0 : 1 - ssRes / ssTot;

  return { slope, intercept, r2, n };
}

// Percentiel (lineaire interpolatie) uit een ongesorteerde reeks.
export function percentile(values: number[], p: number): number | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  if (sorted.length === 1) return sorted[0];
  const idx = (sorted.length - 1) * p;
  const lo = Math.floor(idx);
  const hi = Math.ceil(idx);
  if (lo === hi) return sorted[lo];
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (idx - lo);
}
