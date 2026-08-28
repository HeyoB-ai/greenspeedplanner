// ════════════════════════════════════════════════════════════════════════
// Greenspeed Planner — woonadres in, afstanden uit
// ════════════════════════════════════════════════════════════════════════
// Supabase Edge Function (Deno). Neemt een woonadres aan, geocodeert het,
// berekent de route-afstand naar alle apotheken waar de koerier mee te maken
// heeft, en schrijft ALLEEN die afstanden weg in courier_distances.
//
// HET ADRES WORDT NERGENS BEWAARD. Niet in de database, niet in een logregel.
// Het bestaat alleen in het geheugen van deze aanroep en in het verzoek aan de
// geocoder. Daarom staat er hieronder ook nergens console.log van het adres of
// van de coördinaten die eruit komen: een logregel is ook een bewaarplaats.
//
// Wie mag dit? Alleen een ingelogde planner. De aanroeper stuurt zijn eigen
// sessie mee; die wordt hier geverifieerd en tegen user_profiles.role gehouden.
// Zonder die controle zou iedereen met de anon-key afstanden kunnen overschrijven
// — en dus vergoedingen kunnen sturen.
//
// AFSTAND = ENKELE REIS over de werkelijke route (Google Distance Matrix,
// mode=driving). Ook voor fietsdiensten: de vergoeding gaat over de gereden
// kilometers tussen twee punten, en de rijafstand is de maat die iedereen kan
// nalopen. Lukt de routeberekening niet, dan volgt een hemelsbrede benadering
// met omrijfactor en die rij krijgt source = 'fallback' — zichtbaar minder hard.
// ════════════════════════════════════════════════════════════════════════

import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const SUPABASE_URL     = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const ANON_KEY         = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const GOOGLE_KEY       = Deno.env.get('GOOGLE_MAPS_API_KEY') ?? '';
const ORIGIN           = Deno.env.get('DECLARATION_ORIGIN') ?? '*';

// Hemelsbreed × dit getal ≈ rijafstand in stedelijk Nederland. Alleen gebruikt
// als de routeberekening niets oplevert.
const DETOUR_FACTOR = 1.35;

// Distance Matrix accepteert 25 bestemmingen per aanroep.
const CHUNK = 25;

const ACCEPTED_LOCATION_TYPES = ['ROOFTOP', 'RANGE_INTERPOLATED'];

const CORS = {
  'Access-Control-Allow-Origin': ORIGIN,
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Vary': 'Origin',
};

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}

interface Pharmacy { id: string; name: string; lat: number; lng: number }

const EARTH_RADIUS_KM = 6371;
const toRad = (d: number) => (d * Math.PI) / 180;

function haversineKm(a: { lat: number; lng: number }, b: { lat: number; lng: number }): number {
  const dLat = toRad(b.lat - a.lat);
  const dLng = toRad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2
    + Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_RADIUS_KM * Math.asin(Math.min(1, Math.sqrt(h)));
}

// ── Geocoder ─────────────────────────────────────────────────────────────
// Zelfde kwaliteitseisen als scripts/backfill-pharmacy-coords.mjs: een adres dat
// de geocoder maar half herkent levert een punt midden in een wijk op, en dat
// zou hier stilzwijgend in iemands vergoeding terechtkomen.
async function geocode(address: string): Promise<
  { ok: true; lat: number; lng: number } | { ok: false; reason: string }
> {
  const url = 'https://maps.googleapis.com/maps/api/geocode/json'
    + `?address=${encodeURIComponent(address)}&region=nl&key=${GOOGLE_KEY}`;
  const res = await fetch(url);
  const data = await res.json();

  if (data.status !== 'OK' || !data.results?.length) {
    return { ok: false, reason: `adres niet gevonden (${data.status})` };
  }
  const r = data.results[0];
  const type = r.geometry?.location_type ?? null;
  if (r.partial_match === true) {
    return { ok: false, reason: 'adres maar gedeeltelijk herkend — controleer straat, huisnummer en postcode' };
  }
  if (!ACCEPTED_LOCATION_TYPES.includes(type)) {
    return { ok: false, reason: `adres te grof gevonden (${type}) — vul huisnummer en postcode in` };
  }
  return { ok: true, lat: r.geometry.location.lat, lng: r.geometry.location.lng };
}

// ── Route-afstanden ──────────────────────────────────────────────────────
// Geeft per bestemming de afstand in kilometers, of null als deze rit niet
// berekend kon worden.
async function routeDistances(
  origin: { lat: number; lng: number }, targets: Pharmacy[],
): Promise<(number | null)[]> {
  const out: (number | null)[] = [];

  for (let i = 0; i < targets.length; i += CHUNK) {
    const slice = targets.slice(i, i + CHUNK);
    const dest = slice.map((p) => `${p.lat},${p.lng}`).join('|');
    const url = 'https://maps.googleapis.com/maps/api/distancematrix/json'
      + `?origins=${origin.lat},${origin.lng}`
      + `&destinations=${encodeURIComponent(dest)}`
      + `&mode=driving&units=metric&region=nl&key=${GOOGLE_KEY}`;

    try {
      const res = await fetch(url);
      const data = await res.json();
      const elements = data.status === 'OK' ? (data.rows?.[0]?.elements ?? []) : [];
      for (let j = 0; j < slice.length; j++) {
        const el = elements[j];
        out.push(el?.status === 'OK' && el?.distance?.value != null
          ? el.distance.value / 1000
          : null);
      }
    } catch (e) {
      console.error('[afstanden] Distance Matrix mislukt:', e instanceof Error ? e.message : String(e));
      for (let j = 0; j < slice.length; j++) out.push(null);
    }
  }

  return out;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Methode niet toegestaan.' }, 405);

  if (!SUPABASE_URL || !SERVICE_ROLE_KEY || !ANON_KEY) {
    return json({ error: 'De server is niet goed ingesteld.' }, 500);
  }
  if (!GOOGLE_KEY) {
    return json({ error: 'GOOGLE_MAPS_API_KEY ontbreekt — zonder geocoder is er niets te berekenen.' }, 500);
  }

  // ── 1. Wie klopt er aan ─────────────────────────────────────────────────
  const authHeader = req.headers.get('Authorization') ?? '';
  const caller = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: { user } } = await caller.auth.getUser();
  if (!user) return json({ error: 'Niet ingelogd.' }, 401);

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const { data: me } = await admin
    .from('user_profiles').select('role').eq('id', user.id).single();
  if (!me || !['superuser', 'supervisor', 'admin'].includes(me.role)) {
    return json({ error: 'Alleen planners mogen afstanden berekenen.' }, 403);
  }

  // ── 2. Wat er gevraagd wordt ────────────────────────────────────────────
  let body: { courier_id?: unknown; address?: unknown };
  try {
    body = await req.json();
  } catch {
    return json({ error: 'Onleesbare aanvraag.' }, 400);
  }
  const courierId = typeof body.courier_id === 'string' ? body.courier_id : '';
  const address   = typeof body.address === 'string' ? body.address.trim() : '';
  if (!courierId) return json({ error: 'Geen koerier opgegeven.' }, 400);
  if (address.length < 6) return json({ error: 'Vul een volledig adres in (straat, huisnummer, postcode).' }, 400);

  const { data: courier } = await admin
    .from('user_profiles').select('id, name, role, home_pharmacy_id')
    .eq('id', courierId).single();
  if (!courier || courier.role !== 'courier') {
    return json({ error: 'Onbekende koerier.' }, 404);
  }

  // ── 3. Welke apotheken ──────────────────────────────────────────────────
  // Alles waar de koerier toegang toe heeft (courier_pharmacy_access) plus zijn
  // standplaats. De tak "andere apotheek" van de rekenregel heeft die hele set
  // nodig: zonder afstand naar een apotheek waar hij ooit komt, blijft de
  // declaratie daar onvolledig.
  const { data: access } = await admin
    .from('courier_pharmacy_access').select('pharmacy_id').eq('courier_id', courierId);

  const wanted = new Set<string>((access ?? []).map((r: { pharmacy_id: string }) => r.pharmacy_id));
  if (courier.home_pharmacy_id) wanted.add(courier.home_pharmacy_id);
  if (wanted.size === 0) {
    return json({ error: 'Deze koerier is nog aan geen enkele apotheek gekoppeld.' }, 400);
  }

  const { data: pharmRows } = await admin
    .from('pharmacies').select('id, name, addressLat, addressLng')
    .in('id', [...wanted]);

  const targets: Pharmacy[] = [];
  const skipped: { id: string; name: string; reason: string }[] = [];
  for (const p of (pharmRows ?? []) as Array<{ id: string; name: string; addressLat: number | null; addressLng: number | null }>) {
    if (p.addressLat == null || p.addressLng == null) {
      // De bekende blokkade: een apotheek zonder adresgegevens is geen fout van
      // deze koerier. Overslaan, benoemen, en de rest gewoon berekenen.
      skipped.push({ id: p.id, name: p.name, reason: 'apotheek heeft geen coördinaten' });
      continue;
    }
    targets.push({ id: p.id, name: p.name, lat: p.addressLat, lng: p.addressLng });
  }

  if (targets.length === 0) {
    return json({
      error: 'Geen van de apotheken van deze koerier heeft coördinaten. Vul eerst de adressen aan.',
      skipped,
    }, 400);
  }

  // ── 4. Adres → punt ─────────────────────────────────────────────────────
  let home: { lat: number; lng: number };
  try {
    const g = await geocode(address);
    if (!g.ok) return json({ error: g.reason }, 400);
    home = { lat: g.lat, lng: g.lng };
  } catch (e) {
    console.error('[afstanden] geocoder onbereikbaar:', e instanceof Error ? e.message : String(e));
    return json({ error: 'De geocoder is niet bereikbaar. Probeer het later opnieuw.' }, 502);
  }

  // ── 5. Punt → afstanden → database ──────────────────────────────────────
  const routed = await routeDistances(home, targets);

  const rows = targets.map((p, i) => {
    const km = routed[i];
    return {
      courier_id: courierId,
      pharmacy_id: p.id,
      distance_km: Number((km ?? haversineKm(home, p) * DETOUR_FACTOR).toFixed(2)),
      source: km != null ? 'route' : 'fallback',
      computed_at: new Date().toISOString(),
    };
  });

  const { error: upErr } = await admin
    .from('courier_distances')
    .upsert(rows, { onConflict: 'courier_id,pharmacy_id' });

  if (upErr) {
    console.error('[afstanden] wegschrijven mislukt:', upErr.message);
    return json({ error: 'De afstanden konden niet opgeslagen worden.' }, 500);
  }

  // Het adres en de coördinaten gaan hier bewust NIET in het antwoord: de planner
  // heeft ze niet nodig en ze zouden alsnog in een browserlog of screenshot
  // belanden. Alleen de uitkomst per apotheek.
  const byId = new Map(targets.map((p) => [p.id, p.name]));
  return json({
    ok: true,
    courier: courier.name,
    distances: rows.map((r) => ({
      pharmacy_id: r.pharmacy_id,
      pharmacy_name: byId.get(r.pharmacy_id) ?? r.pharmacy_id,
      distance_km: r.distance_km,
      source: r.source,
    })).sort((a, b) => a.pharmacy_name.localeCompare(b.pharmacy_name, 'nl')),
    fallbacks: rows.filter((r) => r.source === 'fallback').length,
    skipped,
  }, 200);
});
