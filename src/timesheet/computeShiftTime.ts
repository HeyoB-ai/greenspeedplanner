// ── Rekenmodel diensttijd — pure functies, geen Supabase ────────────────────
// Begintijd = eerste inscan − voormarge.
// Eindtijd  = laatste deurscan + berekende terugreis + afrondmarge.
// De berekende tijd is een VOORSTEL. Bij twijfel geven we GEEN getal terug maar
// status 'disputed' met een reden: fout raden is duurder dan niets teruggeven.

import {
  DEFAULT_SPEED_MPS, DETOUR_FACTOR, GAP_THRESHOLD_MIN, GPS_ZERO_EPS,
  MAX_WINDOW_HOURS, MIN_LEG_DISTANCE_M, MIN_USABLE_LEGS, MODEL_VERSION,
  PRE_MARGIN_MIN, ROUND_MARGIN_MIN,
} from './constants';
import { haversineMeters, linearRegression, Regression } from './geo';

export type TransportMode = 'bike' | 'car';

// Eén deurscan = één deliveryEvidence-punt (afgeleverd óf niet-thuis; beide zijn
// een geldig einde van een stop).
export interface DoorScan {
  timestamp: string; // ISO
  lat: number;
  lng: number;
}

export interface SpeedFallback {
  level: string;    // 'pharmacy' | 'group' | 'national' — welk niveau leverde de snelheid
  speedMps: number;
}

export interface ComputeInput {
  firstInscanAt: string | null;         // min(createdAt) van de dienst
  doorScans: DoorScan[];                 // deliveryEvidence-punten, ongesorteerd
  pharmacy: { lat: number; lng: number } | null; // thuisbasis voor de terugreis
  transportMode: TransportMode;
  linkageAmbiguous: boolean;             // scans niet eenduidig aan één dienst te koppelen
  fallback?: SpeedFallback;              // gebruikt als er te weinig eigen trajecten zijn
  // Gezet als deze dienst er meerdere op één dag deelt en de pakketten eenduidig
  // op apotheek gesplitst zijn (zie de kalibratie). Puur voor herleidbaarheid.
  attribution?: { splitByPharmacy: boolean; pharmacies: string[] };
}

export interface CalcGap {
  fromTs: string;
  toTs: string;
  gapMin: number;
  distanceM: number;
  expectedTravelMin: number;
  onverklaardMin: number;
}

export interface CalcDetails {
  modelVersion: string;
  preMarginMin: number;
  roundMarginMin: number;
  detourFactor: number;
  totalDoorScans: number;
  gpsDoorScans: number;
  usableLegs: number;
  speedMps: number | null;
  speedSource: string;              // 'measured' | fallback-niveau
  handoverSec: number | null;       // uit de regressie
  regression: Regression | null;
  returnDistanceM: number | null;
  returnSec: number | null;
  windowHours: number | null;
  gaps: CalcGap[];
  // Herkomst van de pakket-toewijzing bij een gedeelde dag: gesplitst op welke
  // apotheken. null = geen split (enkele dienst die dag).
  attribution: { splitByPharmacy: boolean; pharmacies: string[] } | null;
  notes: string[];
}

interface Raw {
  firstScanAt: string | null;
  lastScanAt: string | null;
  lastScanLat: number | null;
  lastScanLng: number | null;
}

export type ComputeResult =
  | ({ status: 'computed'; computedStart: string; computedEnd: string; calcDetails: CalcDetails } & Raw)
  | ({ status: 'disputed'; disputeReason: string; calcDetails: CalcDetails } & Raw);

function isValidGps(lat: number, lng: number): boolean {
  return Number.isFinite(lat) && Number.isFinite(lng)
    && !(Math.abs(lat) < GPS_ZERO_EPS && Math.abs(lng) < GPS_ZERO_EPS);
}

const addMinutes = (iso: string, min: number) => new Date(new Date(iso).getTime() + min * 60_000).toISOString();
const addSeconds = (iso: string, sec: number) => new Date(new Date(iso).getTime() + sec * 1000).toISOString();

export function computeShiftTime(input: ComputeInput): ComputeResult {
  const notes: string[] = [];
  const details: CalcDetails = {
    modelVersion: MODEL_VERSION,
    preMarginMin: PRE_MARGIN_MIN,
    roundMarginMin: ROUND_MARGIN_MIN,
    detourFactor: DETOUR_FACTOR,
    totalDoorScans: input.doorScans.length,
    gpsDoorScans: 0,
    usableLegs: 0,
    speedMps: null,
    speedSource: 'onbepaald',
    handoverSec: null,
    regression: null,
    returnDistanceM: null,
    returnSec: null,
    windowHours: null,
    gaps: [],
    attribution: input.attribution ?? null,
    notes,
  };

  const scans = [...input.doorScans]
    .filter((s) => s.timestamp)
    .sort((a, b) => new Date(a.timestamp).getTime() - new Date(b.timestamp).getTime());
  const gpsScans = scans.filter((s) => isValidGps(s.lat, s.lng));
  details.gpsDoorScans = gpsScans.length;

  const empty: Raw = { firstScanAt: input.firstInscanAt, lastScanAt: null, lastScanLat: null, lastScanLng: null };
  const dispute = (reason: string, raw: Raw): ComputeResult =>
    ({ status: 'disputed', disputeReason: reason, calcDetails: details, ...raw });

  // ── Harde afvang-gevallen ─────────────────────────────────────────────
  if (!input.firstInscanAt) return dispute('geen_inscan', empty);
  if (scans.length === 0) return dispute('geen_deurscan', empty);
  if (input.linkageAmbiguous) {
    return dispute('meerdere_diensten_zelfde_dag', { ...empty, lastScanAt: scans[scans.length - 1].timestamp });
  }

  const last = scans[scans.length - 1];
  const raw: Raw = {
    firstScanAt: input.firstInscanAt,
    lastScanAt: last.timestamp,
    lastScanLat: isValidGps(last.lat, last.lng) ? last.lat : null,
    lastScanLng: isValidGps(last.lat, last.lng) ? last.lng : null,
  };

  const windowMs = new Date(last.timestamp).getTime() - new Date(input.firstInscanAt).getTime();
  details.windowHours = windowMs / 3_600_000;
  if (windowMs < 0) return dispute('negatief_venster', raw);
  if (details.windowHours > MAX_WINDOW_HOURS) return dispute('venster_te_lang', raw);

  // ── Snelheid uit eigen trajecten (regressie tijd ~ afstand) ───────────
  const legs: { x: number; y: number; fromTs: string; toTs: string; distanceM: number }[] = [];
  for (let i = 1; i < gpsScans.length; i++) {
    const a = gpsScans[i - 1];
    const b = gpsScans[i];
    const distanceM = haversineMeters(a, b);
    const timeSec = (new Date(b.timestamp).getTime() - new Date(a.timestamp).getTime()) / 1000;
    if (distanceM >= MIN_LEG_DISTANCE_M && timeSec > 0) {
      legs.push({ x: distanceM, y: timeSec, fromTs: a.timestamp, toTs: b.timestamp, distanceM });
    }
  }
  details.usableLegs = legs.length;

  const regression = linearRegression(legs.map((l) => ({ x: l.x, y: l.y })));
  details.regression = regression;

  let speedMps: number;
  if (legs.length >= MIN_USABLE_LEGS && regression && regression.slope > 0) {
    speedMps = 1 / regression.slope;                 // helling = sec/m → snelheid = m/s
    details.handoverSec = Math.max(0, regression.intercept);
    details.speedSource = 'measured';
  } else {
    const fb = input.fallback ?? { level: 'national', speedMps: DEFAULT_SPEED_MPS[input.transportMode] };
    speedMps = fb.speedMps;
    details.speedSource = fb.level;
    notes.push(`Te weinig eigen trajecten (${legs.length} < ${MIN_USABLE_LEGS}); terugval op ${fb.level}.`);
  }
  details.speedMps = speedMps;

  // ── Gaten tussen deurscans die niet door afstand te verklaren zijn ────
  // Het gat wordt NOOIT automatisch afgetrokken; alleen zichtbaar gemaakt.
  const handoverMin = (details.handoverSec ?? 0) / 60;
  for (const leg of legs) {
    const gapMin = leg.y / 60;
    const expectedTravelMin = leg.distanceM / speedMps / 60;
    const onverklaardMin = gapMin - expectedTravelMin - handoverMin;
    if (onverklaardMin > GAP_THRESHOLD_MIN) {
      details.gaps.push({
        fromTs: leg.fromTs, toTs: leg.toTs,
        gapMin: round(gapMin), distanceM: round(leg.distanceM),
        expectedTravelMin: round(expectedTravelMin), onverklaardMin: round(onverklaardMin),
      });
    }
  }

  // ── Terugreis vereist coördinaten van zowel laatste deur als apotheek ─
  if (!input.pharmacy) return dispute('apotheek_geen_coordinaten', raw);
  if (raw.lastScanLat === null || raw.lastScanLng === null) return dispute('laatste_deurscan_geen_gps', raw);

  if (details.gaps.length > 0) return dispute('onverklaard_gat', raw);

  const straightM = haversineMeters(
    { lat: raw.lastScanLat, lng: raw.lastScanLng },
    input.pharmacy,
  );
  details.returnDistanceM = round(straightM * DETOUR_FACTOR);
  details.returnSec = Math.round(details.returnDistanceM / speedMps);

  const computedStart = addMinutes(input.firstInscanAt, -PRE_MARGIN_MIN);
  const computedEnd = addMinutes(addSeconds(last.timestamp, details.returnSec), ROUND_MARGIN_MIN);

  return { status: 'computed', computedStart, computedEnd, calcDetails: details, ...raw };
}

function round(n: number): number {
  return Math.round(n * 100) / 100;
}
