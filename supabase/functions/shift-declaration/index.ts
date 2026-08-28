// ════════════════════════════════════════════════════════════════════════
// Greenspeed Planner — nadeclaratie: de invulpagina achter de link
// ════════════════════════════════════════════════════════════════════════
// Supabase Edge Function (Deno). De koerier klikt vanuit zijn mailbox en vult in
// zonder in te loggen. Deze functie is de ENIGE weg naar shift_declarations:
// die tabel heeft geen enkele RLS-policy (migratie 018, punt 10), dus anon en
// authenticated komen er niet bij. Hier draait de service-role, en het token
// bepaalt welke ene rij bereikbaar is.
//
// Twee ingangen:
//   GET  ?t=<token>   → de gegevens van die ene dienst, ter herkenning
//   POST {token, …}   → de opgave vastleggen
//
// Wat er NIET gebeurt:
//   * er wordt nooit een declaration_id uit de aanvraag gebruikt — het token is
//     het enige aanknopingspunt, dus een token is nooit om te buigen naar een
//     andere dienst;
//   * er komt geen verschil naar buiten tussen "bestaat niet", "verlopen" en
//     "al afgehandeld": alle drie geven hetzelfde antwoord, zodat er niets te
//     leren valt uit het proberen van tokens;
//   * er gaan geen gegevens van andere mensen mee.
// ════════════════════════════════════════════════════════════════════════

import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const SUPABASE_URL     = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

// De invulpagina staat op een ander domein (Netlify) dan deze functie, dus CORS
// is nodig. Zet DECLARATION_ORIGIN op de URL van de planner-app zodra die vast
// staat; '*' is bruikbaar omdat er geen cookies of sessies aan te pas komen —
// het token in de URL is het hele bewijs.
const ORIGIN = Deno.env.get('DECLARATION_ORIGIN') ?? '*';

const CORS = {
  'Access-Control-Allow-Origin': ORIGIN,
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Vary': 'Origin',
};

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}

// 'HH:MM' of 'HH:MM:SS'. Alles wat daar niet op lijkt gaat niet naar de database.
const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$/;

interface SubmitBody {
  token?: unknown;
  actual_start?: unknown;
  actual_end?: unknown;
  claims_travel?: unknown;
  own_car_km?: unknown;
  note?: unknown;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
    return json({ error: 'De server is niet goed ingesteld.' }, 500);
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // ── Ophalen ────────────────────────────────────────────────────────────
  if (req.method === 'GET') {
    const token = new URL(req.url).searchParams.get('t') ?? '';
    if (!token) return json({ error: 'link_ongeldig' }, 404);

    const { data, error } = await admin.rpc('declaration_by_token', { p_token: token });
    if (error) {
      console.error('[declaratie] ophalen mislukt:', error.message);
      return json({ error: 'Er ging iets mis. Probeer het later opnieuw.' }, 500);
    }
    const row = Array.isArray(data) ? data[0] : data;
    if (!row) return json({ error: 'link_ongeldig' }, 404);

    return json({ declaration: row }, 200);
  }

  // ── Indienen ───────────────────────────────────────────────────────────
  if (req.method === 'POST') {
    let body: SubmitBody;
    try {
      body = await req.json();
    } catch {
      return json({ error: 'Onleesbare aanvraag.' }, 400);
    }

    const token = typeof body.token === 'string' ? body.token : '';
    const start = typeof body.actual_start === 'string' ? body.actual_start : '';
    const end   = typeof body.actual_end   === 'string' ? body.actual_end   : '';

    if (!token) return json({ error: 'link_ongeldig' }, 404);
    if (!TIME_RE.test(start) || !TIME_RE.test(end)) {
      return json({ error: 'Vul een begintijd en een eindtijd in als uu:mm.' }, 400);
    }

    // Kilometers: alleen een getal, en alleen als er ook gedeclareerd wordt. De
    // database bewaakt dit ook (trigger op own_car_km, migratie 018), maar een
    // duidelijke melding hier is beter dan een databasefout op de pagina.
    const claims = body.claims_travel === true;
    let km: number | null = null;
    if (claims && body.own_car_km !== null && body.own_car_km !== undefined && body.own_car_km !== '') {
      km = Number(body.own_car_km);
      if (!Number.isFinite(km) || km < 0 || km > 2000) {
        return json({ error: 'Vul een geldig aantal kilometers in.' }, 400);
      }
    }

    const note = typeof body.note === 'string' ? body.note.slice(0, 2000) : null;

    const { error } = await admin.rpc('declaration_submit', {
      p_token: token,
      p_actual_start: start,
      p_actual_end: end,
      p_claims_travel: claims,
      p_own_car_km: km,
      p_note: note,
    });

    if (error) {
      // 28000 zet declaration_submit zelf bij een ongeldige of verlopen link.
      if (error.code === '28000') return json({ error: 'link_ongeldig' }, 404);
      // De overige meldingen uit de functie zijn bewust leesbaar Nederlands
      // ('Vul het aantal gereden kilometers in.') en mogen zo naar de pagina.
      console.warn('[declaratie] indienen geweigerd:', error.message);
      return json({ error: error.message }, 400);
    }

    // Na indienen de bijgewerkte stand teruggeven, zodat de pagina kan tonen wat
    // er is vastgelegd zonder een tweede ronde.
    const { data } = await admin.rpc('declaration_by_token', { p_token: token });
    const row = Array.isArray(data) ? data[0] : data;
    return json({ ok: true, declaration: row ?? null }, 200);
  }

  return json({ error: 'Methode niet toegestaan.' }, 405);
});
