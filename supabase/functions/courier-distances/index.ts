// ════════════════════════════════════════════════════════════════════════
// Greenspeed Planner — woonadres in, afstanden uit
// ════════════════════════════════════════════════════════════════════════
// Supabase Edge Function (Deno). Geocodeert het woonadres van een koerier,
// berekent de route-afstand naar alle apotheken waar hij mee te maken heeft, en
// schrijft die afstanden weg in courier_distances.
//
// WAAR HET ADRES VANDAAN KOMT — sinds 7 oktober 2026 (migratie 057)
//   Het adres wordt bewaard, in employee_addresses. Wordt er geen adres
//   meegestuurd, dan leest deze functie het bewaarde adres van deze koerier zelf
//   (als service_role; de tabel staat dicht voor iedereen behalve planners).
//   Zo kan een afstand opnieuw berekend worden — bijvoorbeeld na een koppeling
//   aan een nieuwe apotheek — zonder dat iemand het adres opnieuw intypt.
//
//   Wordt er wél een adres meegestuurd, dan rekent de functie daarmee en slaat
//   ze het NIET op. Opslaan loopt uitsluitend via courier_address_set(): die
//   controleert wie het doet en legt dat vast. Twee plekken die een adres kunnen
//   wegschrijven zijn er één te veel.
//
// HET ADRES BLIJFT BUITEN ELKE LOGREGEL EN ELK ANTWOORD, net als de coördinaten
// die eruit komen. Dat het adres nu in de database staat is geen reden om het
// ook in de functielogs te zetten: die hebben een andere bewaartermijn, andere
// lezers, en zijn niet te wissen als iemand uit dienst gaat.
//
// Wie mag dit? Alleen een ingelogde planner. De aanroeper stuurt zijn eigen
// sessie mee; die wordt hier geverifieerd en tegen user_profiles.role gehouden.
// Zonder die controle zou iedereen met de anon-key afstanden kunnen overschrijven
// — en dus vergoedingen kunnen sturen.
//
// AFSTAND = ENKELE REIS over de werkelijke route (Google Routes API,
// computeRouteMatrix, travelMode DRIVE). Ook voor fietsdiensten: de vergoeding
// gaat over de gereden kilometers tussen twee punten, en de rijafstand is de maat
// die iedereen kan nalopen.
//
// routingPreference TRAFFIC_UNAWARE: de afstand moet reproduceerbaar zijn. Met
// verkeer erin kiest Google bij file een andere route, en dan krijgt dezelfde
// koerier voor dezelfde rit een andere vergoeding afhankelijk van het uur waarop
// iemand op Berekenen klikte.
//
// Lukt de routeberekening niet, dan volgt een hemelsbrede benadering met
// omrijfactor en die rij krijgt source = 'fallback'. Dat gebeurde tot oktober 2026
// STIL: de legacy Distance Matrix API gaf REQUEST_DENIED — hij is voor nieuwe
// Google-projecten niet meer aan te zetten — en elke afstand werd ongemerkt een
// schatting. Daarom gaat de reden van Google nu mee in het antwoord (route_error)
// en in de log.
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

// Per aanroep naar de Routes API. De limiet is 625 elementen (origins x
// destinations) bij latLng-punten; met één herkomst zouden alle apotheken in één
// keer kunnen. Kleiner houden betekent dat een fout bij Google hooguit een deel
// van de afstanden een schatting maakt, en niet alles.
const CHUNK = 25;

const ROUTES_URL = 'https://routes.googleapis.com/distanceMatrix/v2:computeRouteMatrix';
// Zonder field mask weigert computeRouteMatrix. Alleen wat we gebruiken: minder
// data over de lijn, en geen duur die suggereert dat we hem ergens voor nodig
// hebben.
const ROUTES_FIELD_MASK = 'originIndex,destinationIndex,distanceMeters,condition,status';

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

// ── Het bewaarde adres ───────────────────────────────────────────────────
// Via employees.user_profile_id van koerier naar medewerker, dan het adres. Elke
// uitkomst die geen adres oplevert krijgt een melding waar de planner iets mee
// kan; de foutteksten van de database zelf gaan alleen naar de log, en die
// bevatten het adres niet.
type Admin = ReturnType<typeof createClient>;

async function storedAddress(admin: Admin, courierId: string): Promise<
  { ok: true; address: string } | { ok: false; status: number; error: string }
> {
  const { data: emp, error: empErr } = await admin
    .from('employees').select('id').eq('user_profile_id', courierId).maybeSingle();
  if (empErr) {
    console.error('[afstanden] medewerker zoeken mislukt:', empErr.message);
    return { ok: false, status: 500, error: 'Het bewaarde adres kon niet gelezen worden.' };
  }
  if (!emp) {
    return {
      ok: false, status: 400,
      error: 'Deze koerier heeft geen medewerkerregel, dus er is geen adres bewaard. '
           + 'Koppel hem eerst onder Beheer → Medewerkers.',
    };
  }

  const { data: row, error: adrErr } = await admin
    .from('employee_addresses').select('address_line').eq('employee_id', (emp as { id: string }).id).maybeSingle();
  if (adrErr) {
    console.error('[afstanden] adres lezen mislukt:', adrErr.message);
    return { ok: false, status: 500, error: 'Het bewaarde adres kon niet gelezen worden.' };
  }
  const line = (row as { address_line?: string } | null)?.address_line?.trim() ?? '';
  if (!line) {
    return {
      ok: false, status: 400,
      error: 'Van deze koerier is nog geen woonadres bekend. Vul het in onder Beheer → Afstanden en bereken opnieuw.',
    };
  }
  return { ok: true, address: line };
}

// ── Route-afstanden ──────────────────────────────────────────────────────
// Een foutmelding van Google gaat naar de log én naar de planner. Zo'n melding
// kan een waarde uit het verzoek herhalen — bij een ongeldig verzoek bijvoorbeeld
// "Invalid value at 'origins[0]...latitude', 52.27…". Getallen die op een
// coördinaat lijken gaan er daarom uit, en de lengte is begrensd.
function scrub(message: string): string {
  return message.replace(/-?\d{1,3}\.\d{3,}/g, '…').slice(0, 300);
}

const waypoint = (p: { lat: number; lng: number }) =>
  ({ waypoint: { location: { latLng: { latitude: p.lat, longitude: p.lng } } } });

// Geeft per bestemming de afstand in kilometers (null = geen route), plus de
// reden van Google als de aanvraag als geheel mislukte. Een losse bestemming
// zonder route is geen aanvraagfout; dat kan gewoon zo zijn.
async function routeDistances(
  origin: { lat: number; lng: number }, targets: Pharmacy[],
): Promise<{ km: (number | null)[]; error: string | null }> {
  const km: (number | null)[] = new Array(targets.length).fill(null);
  let error: string | null = null;

  for (let i = 0; i < targets.length; i += CHUNK) {
    const slice = targets.slice(i, i + CHUNK);

    try {
      // De sleutel in de header en niet in de URL: een URL komt in logregels en
      // foutmeldingen terecht, een header niet.
      const res = await fetch(ROUTES_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': GOOGLE_KEY,
          'X-Goog-FieldMask': ROUTES_FIELD_MASK,
        },
        body: JSON.stringify({
          origins: [waypoint(origin)],
          destinations: slice.map(waypoint),
          travelMode: 'DRIVE',
          routingPreference: 'TRAFFIC_UNAWARE',
        }),
      });
      const data = await res.json().catch(() => null);

      if (!res.ok || !Array.isArray(data)) {
        const status = String(data?.error?.status ?? `HTTP ${res.status}`);
        const message = scrub(String(data?.error?.message ?? 'onleesbaar antwoord'));
        console.error('[afstanden] Routes API weigerde de aanvraag:', status, message);
        error ??= `${status}: ${message}`;
        continue;
      }

      // Koppelen via destinationIndex, niet via de volgorde: Google levert de
      // elementen in de volgorde waarin ze klaar zijn. Een ontbrekende index is
      // 0 — Google's JSON laat standaardwaarden soms weg.
      let elementErrors = 0;
      let firstElementError: string | null = null;
      for (const el of data) {
        const j = Number(el?.destinationIndex ?? 0);
        if (!Number.isInteger(j) || j < 0 || j >= slice.length) continue;
        if (el?.status?.code) {
          elementErrors++;
          firstElementError ??= `${el.status.code}: ${scrub(String(el.status.message ?? ''))}`;
          continue;
        }
        if (el?.condition === 'ROUTE_EXISTS' && el?.distanceMeters != null) {
          km[i + j] = Number(el.distanceMeters) / 1000;
        }
      }
      if (elementErrors > 0) {
        console.error(`[afstanden] Routes API: ${elementErrors} bestemming(en) met een foutstatus, eerste:`,
          firstElementError);
      }
    } catch (e) {
      // e.name en niet e.message, om dezelfde reden als bij de geocoder: een
      // mislukte fetch zet in Deno de URL in de melding.
      console.error('[afstanden] Routes API onbereikbaar:', e instanceof Error ? e.name : 'onbekende fout');
      error ??= 'De Routes API van Google was niet bereikbaar.';
    }
  }

  return { km, error };
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
  // Meegestuurd is een eenmalige berekening met dit adres; leeg of afwezig
  // betekent: neem het bewaarde. Een te kort adres is een invoerfout en geen
  // verzoek om het bewaarde te gebruiken — dan zou een tikfout stilletjes met
  // een ander adres rekenen dan er in beeld stond.
  const given     = typeof body.address === 'string' ? body.address.trim() : '';
  if (!courierId) return json({ error: 'Geen koerier opgegeven.' }, 400);
  if (given !== '' && given.length < 6) {
    return json({ error: 'Vul een volledig adres in (straat, huisnummer, postcode).' }, 400);
  }

  const { data: courier } = await admin
    .from('user_profiles').select('id, name, role, home_pharmacy_id')
    .eq('id', courierId).single();
  if (!courier || courier.role !== 'courier') {
    return json({ error: 'Onbekende koerier.' }, 404);
  }

  let address = given;
  if (!address) {
    const stored = await storedAddress(admin, courierId);
    if (!stored.ok) return json({ error: stored.error }, stored.status);
    address = stored.address;
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
    // e.name en niet e.message: een mislukte fetch zet in Deno de volledige URL
    // in de melding — met het adres én de Google-sleutel erin.
    console.error('[afstanden] geocoder onbereikbaar:', e instanceof Error ? e.name : 'onbekende fout');
    return json({ error: 'De geocoder is niet bereikbaar. Probeer het later opnieuw.' }, 502);
  }

  // ── 5. Punt → afstanden → database ──────────────────────────────────────
  const routed = await routeDistances(home, targets);

  const rows = targets.map((p, i) => {
    const km = routed.km[i];
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
    // De reden van Google als de routeberekening als geheel mislukte. Zonder dit
    // veld werd een afgewezen aanvraag een stille schatting.
    route_error: routed.error,
    skipped,
  }, 200);
});
