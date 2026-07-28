// ─────────────────────────────────────────────────────────────────────────
// Kalibratie: draait het rekenmodel over de bestaande, afgeronde diensten en
// rapporteert de verdeling. Dit is de ijkstap vóór er ook maar één mail uitgaat.
//
// Draaien vanuit C:\Users\TechnoHUB7\Greenspeedplanner:
//   $env:SUPABASE_SERVICE_ROLE_KEY="<service-role-key>"
//   npx tsx scripts/calibrate-timesheets.ts [--write] [--from=YYYY-MM-DD] [--to=YYYY-MM-DD]
//
//   --write  schrijft de uitkomsten naar shift_time_reports (upsert op shift_id).
//            Zonder --write draait het model dry en rapporteert alleen.
//
// Service-role omdat packages/RLS anders niet leesbaar zijn. De DB-glue zit
// hier; het model (computeShiftTime) blijft puur en los testbaar.
// ─────────────────────────────────────────────────────────────────────────

import { readFileSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';
import { computeShiftTime, ComputeInput, DoorScan, TransportMode } from '../src/timesheet/computeShiftTime';
import { DEFAULT_SPEED_MPS, SEED_EXCLUDED_PHARMACY_IDS } from '../src/timesheet/constants';
import { percentile } from '../src/timesheet/geo';

// Seed-/testapotheken die nooit meetellen (bv. ph-1 "Test Apotheek"). Expliciet,
// niet leunend op ontbrekende coördinaten. Zie constants.ts.
const EXCLUDED_PHARMACIES = new Set(SEED_EXCLUDED_PHARMACY_IDS);

function readEnvFile(path: string): Record<string, string> {
  const out: Record<string, string> = {};
  try {
    for (const line of readFileSync(path, 'utf8').split(/\r?\n/)) {
      const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
      if (m) out[m[1]] = m[2];
    }
  } catch { /* geen .env */ }
  return out;
}

const fileEnv = readEnvFile('./.env');
const SUPABASE_URL = process.env.SUPABASE_URL || fileEnv.VITE_SUPABASE_URL;
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
function die(msg: string): never { console.error('✗ ' + msg); process.exit(1); }
if (!SUPABASE_URL) die('SUPABASE_URL / VITE_SUPABASE_URL ontbreekt.');
if (!SERVICE_ROLE_KEY) die('Zet SUPABASE_SERVICE_ROLE_KEY in je environment.');

const args = process.argv.slice(2);
const WRITE = args.includes('--write');
const argFrom = args.find((a) => a.startsWith('--from='))?.split('=')[1];
const argTo = args.find((a) => a.startsWith('--to='))?.split('=')[1];

const sb = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const dateOf = (iso: string) => iso.slice(0, 10);
const minsBetween = (aIso: string, bIso: string) =>
  (new Date(bIso).getTime() - new Date(aIso).getTime()) / 60_000;

// Duur in minuten van een TIME-venster (start_time → budgeted_end_time).
function budgetedDurationMin(start: string | null, end: string | null): number | null {
  if (!start || !end) return null;
  const toMin = (t: string) => {
    const [h, m] = t.split(':').map(Number);
    return h * 60 + m;
  };
  const d = toMin(end) - toMin(start);
  return d > 0 ? d : null;
}

async function fetchAllPackages(from: string, to: string): Promise<any[]> {
  const page = 1000;
  const rows: any[] = [];
  for (let offset = 0; ; offset += page) {
    const { data, error } = await sb
      .from('packages')
      .select('courierId, createdAt, pharmacyId, deliveryEvidence')
      .gte('createdAt', from)
      .lte('createdAt', to + 'T23:59:59.999')
      .not('courierId', 'is', null)
      .range(offset, offset + page - 1);
    if (error) die('Ophalen packages mislukt: ' + error.message);
    rows.push(...(data ?? []));
    if (!data || data.length < page) break;
  }
  return rows;
}

async function main() {
  // 1. Afgeronde diensten met een koerier.
  const today = new Date().toISOString().slice(0, 10);
  // Concept-diensten ('draft') tellen NOOIT mee. Én harde filter op
  // timing_reliable: alleen diensten die de planner als volledige, echte rit
  // heeft gemarkeerd komen in de kalibratie (default false → standaard eruit).
  let q = sb
    .from('shifts')
    .select('id, courier_id, shift_date, start_time, budgeted_end_time, transport_mode')
    .not('courier_id', 'is', null)
    .neq('status', 'draft')
    .eq('timing_reliable', true)
    .lt('shift_date', today);
  if (argFrom) q = q.gte('shift_date', argFrom);
  if (argTo) q = q.lte('shift_date', argTo);
  const { data: shifts, error: shiftErr } = await q;
  if (shiftErr) die('Ophalen shifts mislukt: ' + shiftErr.message);
  if (!shifts || shifts.length === 0) die('Geen afgeronde diensten met koerier gevonden.');

  const shiftIds = shifts.map((s) => s.id);
  const dates = shifts.map((s) => s.shift_date).sort();
  const fromDate = argFrom ?? dates[0];
  const toDate = argTo ?? dates[dates.length - 1];

  // 2. Koppeltabel + apotheekcoördinaten.
  const { data: sp } = await sb.from('shift_pharmacies').select('shift_id, pharmacy_id').in('shift_id', shiftIds);
  const { data: pharmacies } = await sb.from('pharmacies').select('id, name, addressLat, addressLng');
  const pharmacyById = new Map<string, any>((pharmacies ?? []).map((p) => [p.id, p]));
  const pharmaciesByShift = new Map<string, string[]>();
  (sp ?? []).forEach((r) => {
    const list = pharmaciesByShift.get(r.shift_id) ?? [];
    list.push(r.pharmacy_id);
    pharmaciesByShift.set(r.shift_id, list);
  });

  // 3. Packages van het venster, geïndexeerd op courier+datum.
  console.log(`Packages ophalen (${fromDate} .. ${toDate})…`);
  const packages = await fetchAllPackages(fromDate, toDate);
  const pkgByCourierDate = new Map<string, any[]>();
  for (const p of packages) {
    if (!p.courierId || !p.createdAt) continue;
    const key = `${p.courierId}|${dateOf(p.createdAt)}`;
    const list = pkgByCourierDate.get(key) ?? [];
    list.push(p);
    pkgByCourierDate.set(key, list);
  }

  // Aantal diensten per courier+datum → basis voor linkage-ambiguïteit (2b).
  const shiftsPerCourierDate = new Map<string, any[]>();
  for (const s of shifts) {
    const key = `${s.courier_id}|${s.shift_date}`;
    const list = shiftsPerCourierDate.get(key) ?? [];
    list.push(s);
    shiftsPerCourierDate.set(key, list);
  }

  // 4. Per dienst het model draaien.
  const results: { shift: any; result: ReturnType<typeof computeShiftTime> }[] = [];
  let skippedSeed = 0;
  for (const shift of shifts) {
    // Diensten volledig voor een seed-/testapotheek overslaan (geen berekening).
    const shiftPhs = pharmaciesByShift.get(shift.id) ?? [];
    if (shiftPhs.length > 0 && shiftPhs.every((id) => EXCLUDED_PHARMACIES.has(id))) {
      skippedSeed++;
      continue;
    }

    const key = `${shift.courier_id}|${shift.shift_date}`;
    const sameDay = shiftsPerCourierDate.get(key) ?? [shift];
    const linkageAmbiguous = disambiguate(shift, sameDay, pharmaciesByShift);

    // Pakketten van seed-apotheken uit de scandata weren.
    const pkgs = (pkgByCourierDate.get(key) ?? []).filter((p) => !EXCLUDED_PHARMACIES.has(p.pharmacyId));
    const sorted = [...pkgs].sort((a, b) => new Date(a.createdAt).getTime() - new Date(b.createdAt).getTime());
    const firstInscanAt = sorted.length ? sorted[0].createdAt : null;

    const doorScans: DoorScan[] = sorted
      .map((p) => p.deliveryEvidence)
      .filter((e) => e && e.timestamp)
      .map((e) => ({ timestamp: e.timestamp, lat: Number(e.latitude), lng: Number(e.longitude) }));

    // Basis-apotheek = waar de eerste inscan viel; anders de eerste koppel-apotheek.
    const basePharmacyId = sorted[0]?.pharmacyId ?? (pharmaciesByShift.get(shift.id) ?? [])[0];
    const ph = basePharmacyId ? pharmacyById.get(basePharmacyId) : null;
    const pharmacy = ph && ph.addressLat != null && ph.addressLng != null
      ? { lat: Number(ph.addressLat), lng: Number(ph.addressLng) }
      : null;

    const transportMode: TransportMode = shift.transport_mode === 'car' ? 'car' : 'bike';
    const input: ComputeInput = {
      firstInscanAt,
      doorScans,
      pharmacy,
      transportMode,
      linkageAmbiguous,
      fallback: { level: 'national', speedMps: DEFAULT_SPEED_MPS[transportMode] },
    };
    results.push({ shift, result: computeShiftTime(input) });
  }

  // 5. Rapporteren.
  if (skippedSeed > 0) console.log(`Overgeslagen (volledig seed-apotheek): ${skippedSeed}`);
  report(results);

  // 6. Optioneel wegschrijven.
  if (WRITE) {
    console.log('\n--write: wegschrijven naar shift_time_reports…');
    let ok = 0;
    for (const { shift, result } of results) {
      const row: any = {
        shift_id: shift.id,
        first_scan_at: result.firstScanAt,
        last_scan_at: result.lastScanAt,
        last_scan_lat: result.lastScanLat,
        last_scan_lng: result.lastScanLng,
        calc_details: result.calcDetails,
        status: result.status,
        computed_start: result.status === 'computed' ? result.computedStart : null,
        computed_end: result.status === 'computed' ? result.computedEnd : null,
        dispute_reason: result.status === 'disputed' ? result.disputeReason : null,
      };
      const { error } = await sb.from('shift_time_reports').upsert(row, { onConflict: 'shift_id' });
      if (error) console.error(`  ✗ ${shift.id}: ${error.message}`);
      else ok++;
    }
    console.log(`Weggeschreven: ${ok}/${results.length}.`);
  } else {
    console.log('\n(dry run — voeg --write toe om naar shift_time_reports te schrijven.)');
  }
}

// Bepaalt of de scans van deze dienst eenduidig te koppelen zijn. Bij één dienst
// per courier+datum: eenduidig. Bij meerdere: alleen eenduidig als de
// apotheek-sets van die diensten onderling disjunct zijn (dan valt per pakket via
// pharmacyId te bepalen bij welke dienst het hoort). Anders: ambigu.
function disambiguate(shift: any, sameDay: any[], pharmaciesByShift: Map<string, string[]>): boolean {
  if (sameDay.length <= 1) return false;
  const sets = sameDay.map((s) => new Set(pharmaciesByShift.get(s.id) ?? []));
  for (let i = 0; i < sets.length; i++) {
    for (let j = i + 1; j < sets.length; j++) {
      for (const x of sets[i]) if (sets[j].has(x)) return true; // overlap → ambigu
    }
  }
  return false; // disjunct → (nog) niet als ambigu gemarkeerd
}

function report(results: { shift: any; result: ReturnType<typeof computeShiftTime> }[]) {
  const total = results.length;
  const byStatus = new Map<string, number>();
  const disputeReasons = new Map<string, number>();
  const speedSources = new Map<string, number>();
  const returnSecs: number[] = [];
  const durationDiffs: number[] = [];   // computed − budgeted (min)
  const computedDurations: number[] = [];
  const measuredSpeedByPharmacy = new Map<string, number>(); // #metingen per basis-apotheek

  for (const { shift, result } of results) {
    byStatus.set(result.status, (byStatus.get(result.status) ?? 0) + 1);
    const src = result.calcDetails.speedSource;
    speedSources.set(src, (speedSources.get(src) ?? 0) + 1);

    if (result.status === 'disputed') {
      disputeReasons.set(result.disputeReason, (disputeReasons.get(result.disputeReason) ?? 0) + 1);
      continue;
    }
    if (result.calcDetails.returnSec != null) returnSecs.push(result.calcDetails.returnSec);
    const dur = minsBetween(result.computedStart, result.computedEnd);
    computedDurations.push(dur);
    const budget = budgetedDurationMin(shift.start_time, shift.budgeted_end_time);
    if (budget != null) durationDiffs.push(dur - budget);
  }

  const fmt = (n: number | null) => (n == null ? '—' : n.toFixed(1));
  const dist = (xs: number[], unit: string) =>
    xs.length === 0 ? '—' :
    `min ${fmt(Math.min(...xs))} · med ${fmt(percentile(xs, 0.5))} · p90 ${fmt(percentile(xs, 0.9))} · max ${fmt(Math.max(...xs))} ${unit}`;

  console.log('\n════════════ KALIBRATIERAPPORT ════════════');
  console.log(`Diensten totaal: ${total}`);
  console.log('\nStatus:');
  for (const [k, v] of byStatus) console.log(`  ${k.padEnd(10)} ${v}  (${((v / total) * 100).toFixed(0)}%)`);

  console.log('\nDisputed — redenen:');
  if (disputeReasons.size === 0) console.log('  (geen)');
  for (const [k, v] of [...disputeReasons].sort((a, b) => b[1] - a[1])) console.log(`  ${k.padEnd(28)} ${v}`);

  console.log('\nSnelheidsbron:');
  for (const [k, v] of speedSources) console.log(`  ${k.padEnd(10)} ${v}`);

  console.log('\nBerekende terugreistijd (sec):   ' + dist(returnSecs, 's'));
  console.log('Berekende dienstduur (min):      ' + dist(computedDurations, 'min'));
  console.log('Berekend − gebudgetteerd (min):  ' + dist(durationDiffs, 'min'));

  // 2d — hoeveel eigen metingen per basis-apotheek (input voor de drempel).
  for (const { result } of results) {
    if (result.calcDetails.speedSource === 'measured') {
      // (per-apotheek telling zou de basis-apotheek nodig hebben; hier globaal
      //  aantal 'measured' — per-apotheek/groep aggregatie is een vervolgstap)
      measuredSpeedByPharmacy.set('measured', (measuredSpeedByPharmacy.get('measured') ?? 0) + 1);
    }
  }
  console.log('\nLet op: per-apotheek/groep-drempel (2d) vergt een tweede pass met');
  console.log('groeps-join; deze run rapporteert measured-vs-national globaal.');
  console.log('═══════════════════════════════════════════');
}

main().catch((e) => die(String(e?.stack ?? e)));
