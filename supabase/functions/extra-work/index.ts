// ════════════════════════════════════════════════════════════════════════
// Greenspeed Planner — meerwerk: de pagina voor de apotheek
// ════════════════════════════════════════════════════════════════════════
// Supabase Edge Function (Deno). De apotheek klikt vanuit haar mailbox en
// reageert zonder in te loggen. Zelfde opzet als shift-declaration: extra_work
// heeft geen enkele RLS-policy en geen rechten voor anon of authenticated, dus
// dit is de enige weg erheen. Het token bepaalt welke ene rij bereikbaar is.
//
//   GET  ?t=<token>                    → de melding, ook ná een antwoord
//   POST {token, approve, note}        → goedkeuren of betwisten
//
// Lezen en schrijven zijn twee verschillende vragen. Een link die na het
// antwoord "werkt niet meer" zegt is misleidend — de apotheek wil kunnen
// terugkijken wat ze heeft goedgekeurd. Dat is de les uit migratie 023.
// ════════════════════════════════════════════════════════════════════════

import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const SUPABASE_URL     = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const ORIGIN           = Deno.env.get('DECLARATION_ORIGIN') ?? '*';

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

    const { data, error } = await admin.rpc('extra_work_by_token', { p_token: token });
    if (error) {
      console.error('[meerwerk] ophalen mislukt:', error.message);
      return json({ error: 'Er ging iets mis. Probeer het later opnieuw.' }, 500);
    }
    const row = Array.isArray(data) ? data[0] : data;
    if (!row) return json({ error: 'link_ongeldig' }, 404);

    return json({ extra_work: row }, 200);
  }

  // ── Antwoorden ─────────────────────────────────────────────────────────
  if (req.method === 'POST') {
    let body: { token?: unknown; approve?: unknown; note?: unknown };
    try {
      body = await req.json();
    } catch {
      return json({ error: 'Onleesbare aanvraag.' }, 400);
    }

    const token = typeof body.token === 'string' ? body.token : '';
    if (!token) return json({ error: 'link_ongeldig' }, 404);
    if (typeof body.approve !== 'boolean') {
      return json({ error: 'Kies goedkeuren of niet akkoord.' }, 400);
    }

    const note = typeof body.note === 'string' ? body.note.slice(0, 2000) : null;

    const { error } = await admin.rpc('extra_work_respond', {
      p_token: token, p_approve: body.approve, p_note: note,
    });

    if (error) {
      // 28000: onbekend token — één nietszeggend antwoord, zodat er uit het
      // proberen van tokens niets te leren valt.
      if (error.code === '28000') return json({ error: 'link_ongeldig' }, 404);
      // 45xxx: het token klopt, maar er valt niets meer te doen. De melding zegt
      // wat er aan de hand is; `closed` vertelt de pagina dat de knoppen weg
      // moeten in plaats van een foutregel eronder.
      if (error.code?.startsWith('45')) {
        console.log('[meerwerk] afgesloten:', error.code, error.message);
        return json({ error: error.message, closed: true }, 409);
      }
      console.warn('[meerwerk] antwoord geweigerd:', error.message);
      return json({ error: error.message }, 400);
    }

    const { data } = await admin.rpc('extra_work_by_token', { p_token: token });
    const row = Array.isArray(data) ? data[0] : data;
    return json({ ok: true, extra_work: row ?? null }, 200);
  }

  return json({ error: 'Methode niet toegestaan.' }, 405);
});
