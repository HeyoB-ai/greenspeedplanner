// ─────────────────────────────────────────────────────────────────────────
// Eenmalig, idempotent backfill-script: geocodeert apotheken zónder
// coördinaten en schrijft pharmacies."addressLat"/"addressLng".
//
// Draaien vanuit C:\Users\TechnoHUB7\Greenspeedplanner (PowerShell):
//   $env:SUPABASE_SERVICE_ROLE_KEY="<service-role-key>"
//   $env:GOOGLE_MAPS_API_KEY="<google-geocoding-key>"
//   node scripts/backfill-pharmacy-coords.mjs
//
// Kenmerken:
//   * Idempotent: pakt alleen rijen met lege addressLat/addressLng. Nieuwe
//     apotheken worden opgepakt door een herhaalde run.
//   * Rate-limited (GEOCODE_DELAY_MS tussen calls).
//   * Automatische kwaliteitscontrole (100+ apotheken zijn niet handmatig na te
//     lopen). Een geocode is VERDACHT en wordt NIET weggeschreven wanneer:
//       - location_type niet ROOFTOP of RANGE_INTERPOLATED is, of
//       - partial_match true is, of
//       - de teruggegeven postcode afwijkt van pharmacies.postalCode.
//     Postcode + huisnummer is in NL vrijwel uniek, dus dit filtert scherp.
//   * Verdachte + niet-geocodebare apotheken komen in een aparte controlelijst
//     (scripts/pharmacy-geocode-review.json) en worden NIET gebruikt tot ze
//     handmatig zijn goedgekeurd.
//
// Geocoding gebeurt hier, NOOIT tijdens de tijdsberekening.
// ─────────────────────────────────────────────────────────────────────────

import { readFileSync, writeFileSync } from 'node:fs';
import { createClient } from '@supabase/supabase-js';

const GEOCODE_DELAY_MS = 120;        // ~8 requests/sec, ruim onder Google-limiet
const ACCEPTED_LOCATION_TYPES = ['ROOFTOP', 'RANGE_INTERPOLATED'];
const REVIEW_FILE = 'scripts/pharmacy-geocode-review.json';

function readEnvFile(path) {
  const out = {};
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
const GOOGLE_MAPS_API_KEY = process.env.GOOGLE_MAPS_API_KEY;

function die(msg) { console.error('✗ ' + msg); process.exit(1); }
if (!SUPABASE_URL) die('SUPABASE_URL / VITE_SUPABASE_URL ontbreekt.');
if (!SERVICE_ROLE_KEY) die('Zet SUPABASE_SERVICE_ROLE_KEY in je environment.');
if (!GOOGLE_MAPS_API_KEY) die('Zet GOOGLE_MAPS_API_KEY in je environment.');

const sb = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { autoRefreshToken: false, persistSession: false },
});

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const normalizePostcode = (pc) => (pc ?? '').replace(/\s+/g, '').toUpperCase();

// NL-postcode ergens in een tekst (bv. de vrije adresregel "... 1213 BE Hilversum").
const NL_POSTCODE = /(\d{4})\s?([A-Za-z]{2})/;

// Verwachte postcode voor de kruischeck: de losse kolom als die er is, anders uit
// de vrije adresregel getrokken (die 4 apotheken hebben alleen 'address' gevuld).
function expectedPostcode(p) {
  if (p.postalCode) return p.postalCode;
  const m = p.address && p.address.match(NL_POSTCODE);
  return m ? `${m[1]} ${m[2]}` : null;
}

function buildAddress(p) {
  const parts = [
    [p.street, p.houseNumber].filter(Boolean).join(' '),
    [p.postalCode, p.city].filter(Boolean).join(' '),
  ].filter((s) => s && s.trim());
  if (parts.length > 0) return parts.join(', ') + ', Netherlands';

  // Terugval: de volledige adresregel uit 'address' (soms zonder komma tussen
  // straat en postcode — Google verwerkt vrije-tekst-adressen prima).
  if (p.address && p.address.trim()) {
    const a = p.address.trim();
    return /nederland|netherlands/i.test(a) ? a : `${a}, Netherlands`;
  }
  return null;
}

async function geocode(address) {
  const url = 'https://maps.googleapis.com/maps/api/geocode/json'
    + `?address=${encodeURIComponent(address)}&region=nl&key=${GOOGLE_MAPS_API_KEY}`;
  const res = await fetch(url);
  const data = await res.json();
  if (data.status !== 'OK' || !data.results?.length) {
    return { ok: false, status: data.status, error: data.error_message };
  }
  const r = data.results[0];
  const postal = r.address_components?.find((c) => c.types?.includes('postal_code'))?.long_name ?? null;
  return {
    ok: true,
    lat: r.geometry?.location?.lat,
    lng: r.geometry?.location?.lng,
    locationType: r.geometry?.location_type ?? null,
    partialMatch: r.partial_match === true,
    postal,
  };
}

// Beoordeel de geocode. Geeft een lijst redenen terug; leeg = betrouwbaar.
function qualityIssues(g, pharmacy) {
  const issues = [];
  if (!ACCEPTED_LOCATION_TYPES.includes(g.locationType)) {
    issues.push(`location_type=${g.locationType}`);
  }
  if (g.partialMatch) issues.push('partial_match');
  const expected = expectedPostcode(pharmacy);
  if (expected && g.postal
      && normalizePostcode(g.postal) !== normalizePostcode(expected)) {
    issues.push(`postcode wijkt af (verwacht=${expected}, geocoder=${g.postal})`);
  }
  return issues;
}

async function main() {
  const { data: pharmacies, error } = await sb
    .from('pharmacies')
    .select('id, name, street, houseNumber, postalCode, city, address, addressLat, addressLng')
    .or('addressLat.is.null,addressLng.is.null');
  if (error) die('Ophalen apotheken mislukt: ' + error.message);

  console.log(`${pharmacies.length} apotheken zonder coördinaten.`);
  const review = [];      // gemarkeerd/verdacht — NIET weggeschreven
  const accepted = [];    // betrouwbaar — wél weggeschreven (voor steekproefcontrole)
  let written = 0;

  for (const p of pharmacies) {
    const address = buildAddress(p);
    if (!address) {
      review.push({ id: p.id, name: p.name, reden: ['geen bruikbaar adres'] });
      continue;
    }

    let g;
    try {
      g = await geocode(address);
    } catch (e) {
      review.push({ id: p.id, name: p.name, address, reden: ['netwerkfout: ' + (e?.message ?? e)] });
      await sleep(GEOCODE_DELAY_MS);
      continue;
    }

    if (!g.ok) {
      review.push({ id: p.id, name: p.name, address, reden: [`geocode ${g.status}${g.error ? ': ' + g.error : ''}`] });
      await sleep(GEOCODE_DELAY_MS);
      continue;
    }

    const issues = qualityIssues(g, p);
    if (issues.length > 0) {
      review.push({ id: p.id, name: p.name, address, lat: g.lat, lng: g.lng, reden: issues });
      await sleep(GEOCODE_DELAY_MS);
      continue;
    }

    const { error: updErr } = await sb
      .from('pharmacies')
      .update({ addressLat: g.lat, addressLng: g.lng })
      .eq('id', p.id);
    if (updErr) {
      review.push({ id: p.id, name: p.name, address, reden: ['update mislukt: ' + updErr.message] });
    } else {
      written++;
      accepted.push({ id: p.id, name: p.name, address, lat: g.lat, lng: g.lng });
      console.log(`✓ ${p.name} → ${g.lat}, ${g.lng}`);
    }
    await sleep(GEOCODE_DELAY_MS);
  }

  writeFileSync(REVIEW_FILE, JSON.stringify({ geaccepteerd: accepted, verdacht: review }, null, 2));
  console.log('');
  console.log(`Klaar. ${written} geschreven, ${review.length} ter controle in ${REVIEW_FILE}.`);
  console.log('Verdachte coördinaten zijn NIET weggeschreven en worden pas na goedkeuring gebruikt.');
}

main().catch((e) => die(String(e?.stack ?? e)));
