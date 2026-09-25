// ════════════════════════════════════════════════════════════════════════
// Greenspeed Planner — BENU: het invulformulier van de koerier
// ════════════════════════════════════════════════════════════════════════
// Supabase Edge Function (Deno). De koerier klikt vanuit zijn mailbox en vult
// zonder inlog de PDA-tijden in. Zelfde opzet als extra-work: de benu-tabellen
// hebben geen enkele policy en geen rechten voor anon of authenticated, dus dit
// is de enige weg erheen. Het token bepaalt welke ene dienst bereikbaar is.
//
//   GET  ?t=<courier_token>                       → het formulier
//   POST {token, entries:[…], note}               → indienen
//
// Bij het indienen gaat er per apotheek mét extra minuten meteen een mail uit
// naar het facturatieadres. Dat gebeurt hier en niet in een cron: de apotheek
// moet binnen 48 uur kunnen reageren, en elk uur wachten is een uur minder.
// ════════════════════════════════════════════════════════════════════════

import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const SUPABASE_URL     = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const ORIGIN           = Deno.env.get('DECLARATION_ORIGIN') ?? '*';

const BREVO_API_KEY    = Deno.env.get('BREVO_API_KEY') ?? '';
const MAIL_FROM        = Deno.env.get('MAIL_FROM') ?? '';
const MAIL_FROM_NAME   = Deno.env.get('MAIL_FROM_NAME') ?? 'GoBob Planning';
const MAIL_REPLY_TO    = Deno.env.get('MAIL_REPLY_TO') ?? '';
const PLANNING_PHONE   = Deno.env.get('PLANNING_PHONE') ?? '';

// Waar de apotheekpagina staat. Leeg = geen bruikbare knop, dus dan gaat er
// géén apotheekmail uit; het indienen zelf slaagt wel.
const BENU_PHARMACY_URL = Deno.env.get('BENU_PHARMACY_URL') ?? '';

// Dezelfde fail-closed poort als de cron-functie en send-shift-mail.
const ALLOWLIST = (Deno.env.get('MAIL_ALLOWLIST') ?? '')
  .split(',').map((s) => s.trim().toLowerCase()).filter(Boolean);
const LIVE = (Deno.env.get('MAIL_LIVE') ?? '') === '1';

function gateFor(address: string): { send: boolean; reason?: string } {
  if (ALLOWLIST.length > 0) {
    return ALLOWLIST.includes(address.toLowerCase())
      ? { send: true }
      : { send: false, reason: 'niet op MAIL_ALLOWLIST' };
  }
  if (!LIVE) {
    return { send: false, reason: 'geen MAIL_ALLOWLIST en MAIL_LIVE staat niet aan' };
  }
  return { send: true };
}

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

// ── Wat benu_entry_submit teruggeeft ─────────────────────────────────────
interface ExtraRow {
  pharmacy_id: string;
  pharmacy_name: string;
  billing_email: string | null;
  planned_minutes: number | null;
  pda_minutes: number | null;
  extra_minutes: number;
  pharmacy_token: string;
  // Niet uit de RPC: de reden komt uit de ingediende invoer en wordt er hier
  // bijgezet, zodat de apotheekmail hem kan tonen zonder extra query.
  extra_reason?: string | null;
}

// ── Opmaak ───────────────────────────────────────────────────────────────
const FONT      = 'font-family:Arial,Helvetica,sans-serif;';
const BODY_TEXT = `${FONT}font-size:15px;line-height:22px;color:#334155;`;
const PARA      = `margin:0 0 16px 0;${BODY_TEXT}`;

function esc(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// 'YYYY-MM-DD' → '25-09-2026'. Losse getallen: new Date('2026-09-25') is
// UTC-middernacht en schuift in Amsterdam een dag terug.
function dateNL(iso: string): string {
  const [y, m, d] = iso.split('-');
  return `${d}-${m}-${y}`;
}

// ISO-timestamp → '27-09-2026 om 14:30' in Amsterdamse tijd.
function deadlineNL(iso: string): string {
  const parts = new Intl.DateTimeFormat('nl-NL', {
    timeZone: 'Europe/Amsterdam',
    day: '2-digit', month: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit', hour12: false,
  }).formatToParts(new Date(iso));
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? '';
  return `${get('day')}-${get('month')}-${get('year')} om ${get('hour')}:${get('minute')}`;
}

function closingText(): string {
  return PLANNING_PHONE
    ? `Vragen? Bel of mail de planning: ${PLANNING_PHONE}`
    : 'Vragen? Bel of mail de planning.';
}

function buildPharmacyMail(
  row: ExtraRow, shiftDate: string, courierName: string, link: string,
): { subject: string; text: string; html: string } {
  const subject  = `Extra tijd op ${dateNL(shiftDate)} — graag uw reactie`;
  const greeting = `Beste ${row.pharmacy_name},`;
  const planned  = row.planned_minutes === null ? '—' : String(row.planned_minutes);
  const pda      = row.pda_minutes === null ? '—' : String(row.pda_minutes);
  const deadline = deadlineNL(new Date(Date.now() + 48 * 3600_000).toISOString());

  const feiten = `Koerier ${courierName} heeft vandaag ${row.extra_minutes} minuten langer `
               + `gewerkt dan gepland (gepland: ${planned} min, PDA: ${pda} min).`;
  const reden  = row.extra_reason ? `Toelichting koerier: ${row.extra_reason}` : '';

  const text = [
    greeting,
    '',
    feiten,
    ...(reden ? ['', reden] : []),
    '',
    `Gaat u akkoord? Reageer voor ${deadline} (48 uur):`,
    link || '(geen reactielink beschikbaar — neem contact op met de planning)',
    '',
    'Zonder reactie wordt de extra tijd automatisch goedgekeurd.',
    '',
    closingText(),
    '',
  ].join('\n');

  const html = [
    '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">',
    '<html xmlns="http://www.w3.org/1999/xhtml">',
    '<head>',
    '<meta http-equiv="Content-Type" content="text/html; charset=utf-8" />',
    `<title>${esc(subject)}</title>`,
    '</head>',
    '<body style="margin:0;padding:0;background-color:#f1f5f9;">',
    '<table role="presentation" bgcolor="#f1f5f9" border="0" cellpadding="0" cellspacing="0" width="100%" style="border-collapse:collapse;background-color:#f1f5f9;">',
    '  <tr>',
    '    <td align="center" style="padding:24px 12px;">',
    '      <table role="presentation" bgcolor="#ffffff" border="0" cellpadding="0" cellspacing="0" width="600" style="width:600px;border-collapse:collapse;background-color:#ffffff;">',
    '        <tr>',
    `          <td style="padding:24px;${BODY_TEXT}">`,
    `<p style="${PARA}">${esc(greeting)}</p>`,
    `<p style="${PARA}">${esc(feiten)}</p>`,
    ...(reden ? [`<p style="${PARA}">${esc(reden)}</p>`] : []),
    `<p style="${PARA}">Gaat u akkoord? Reageer voor ${esc(deadline)} (48 uur):</p>`,
    ...(link ? [
      '<table role="presentation" border="0" cellpadding="0" cellspacing="0" style="border-collapse:collapse;margin:0 0 16px 0;">',
      '  <tr>',
      `    <td bgcolor="#006b5a" align="center" style="background-color:#006b5a;border-radius:4px;padding:13px 22px;${FONT}font-size:15px;font-weight:bold;color:#ffffff;">`,
      `      <a href="${esc(link)}" style="${FONT}font-size:15px;font-weight:bold;color:#ffffff;text-decoration:none;">Reageren</a>`,
      '    </td>',
      '  </tr>',
      '</table>',
    ] : []),
    `<p style="${PARA}">Zonder reactie wordt de extra tijd automatisch goedgekeurd.</p>`,
    `<p style="margin:0;${BODY_TEXT}">${esc(closingText())}</p>`,
    '          </td>',
    '        </tr>',
    '      </table>',
    '    </td>',
    '  </tr>',
    '</table>',
    '</body>',
    '</html>',
  ].join('\n');

  return { subject, text, html };
}

async function sendMail(
  to: string, toName: string, subject: string, text: string, html: string,
): Promise<{ ok: boolean; error?: string }> {
  const body: Record<string, unknown> = {
    sender: { name: MAIL_FROM_NAME, email: MAIL_FROM },
    to: [{ email: to, name: toName }],
    subject,
    textContent: text,
    htmlContent: html,
    tags: ['benu-extra-tijd'],
  };
  if (MAIL_REPLY_TO) body.replyTo = { email: MAIL_REPLY_TO };

  const res = await fetch('https://api.brevo.com/v3/smtp/email', {
    method: 'POST',
    headers: {
      'api-key': BREVO_API_KEY,
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    },
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    const raw = await res.text();
    return { ok: false, error: `Brevo ${res.status}: ${raw.slice(0, 300)}` };
  }
  return { ok: true };
}

// ── Hoofdlus ─────────────────────────────────────────────────────────────
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

    const { data, error } = await admin.rpc('benu_entry_by_courier_token', { p_token: token });
    if (error) {
      console.error('[benu-koerier] ophalen mislukt:', error.message);
      return json({ error: 'Er ging iets mis. Probeer het later opnieuw.' }, 500);
    }
    const row = Array.isArray(data) ? data[0] : data;
    if (!row) return json({ error: 'link_ongeldig' }, 404);

    return json({ entry: row }, 200);
  }

  // ── Indienen ───────────────────────────────────────────────────────────
  if (req.method === 'POST') {
    let body: { token?: unknown; entries?: unknown; note?: unknown };
    try {
      body = await req.json();
    } catch {
      return json({ error: 'Onleesbare aanvraag.' }, 400);
    }

    const token = typeof body.token === 'string' ? body.token : '';
    if (!token) return json({ error: 'link_ongeldig' }, 404);

    if (!Array.isArray(body.entries) || body.entries.length === 0) {
      return json({ error: 'Vul voor elke apotheek een tijd in.' }, 400);
    }

    const entries: Array<{ pharmacy_id: string; pda_minutes: number; extra_reason: string | null }> = [];
    for (const raw of body.entries) {
      const e = raw as Record<string, unknown>;
      const pharmacyId = typeof e.pharmacy_id === 'string' ? e.pharmacy_id : '';
      const minutes = Number(e.pda_minutes);
      if (!pharmacyId) return json({ error: 'Onvolledige invoer.' }, 400);
      if (!Number.isInteger(minutes) || minutes < 0) {
        return json({ error: 'Vul bij elke apotheek een heel aantal minuten in, 0 of hoger.' }, 400);
      }
      entries.push({
        pharmacy_id: pharmacyId,
        pda_minutes: minutes,
        extra_reason: typeof e.extra_reason === 'string' && e.extra_reason.trim()
          ? e.extra_reason.trim().slice(0, 500)
          : null,
      });
    }

    const note = typeof body.note === 'string' && body.note.trim()
      ? body.note.trim().slice(0, 500)
      : null;

    // Naam en datum vóór het indienen ophalen: na de submit staat de entry op
    // 'ingediend' en zijn deze gegevens nog steeds nodig voor de apotheekmail.
    const { data: before } = await admin.rpc('benu_entry_by_courier_token', { p_token: token });
    const beforeRow = (Array.isArray(before) ? before[0] : before) as
      { shift_date?: string; courier_name?: string; pharmacies?: Array<Record<string, unknown>> } | null;
    const shiftDate   = beforeRow?.shift_date ?? '';
    const courierName = beforeRow?.courier_name ?? 'de koerier';

    const { data, error } = await admin.rpc('benu_entry_submit', {
      p_token: token, p_entries: entries, p_note: note,
    });

    if (error) {
      // 28000: onbekend token — één nietszeggend antwoord, zodat er uit het
      // proberen van tokens niets te leren valt.
      if (error.code === '28000') return json({ error: 'link_ongeldig' }, 404);
      // 45xxx: het token klopt, maar er valt niets meer te doen. `closed`
      // vertelt de pagina dat het formulier weg moet.
      if (error.code?.startsWith('45')) {
        console.log('[benu-koerier] afgesloten:', error.code, error.message);
        return json({ error: error.message, closed: true }, 409);
      }
      console.warn('[benu-koerier] indienen geweigerd:', error.message);
      return json({ error: error.message }, 400);
    }

    // De ingevulde reden zit niet in het RPC-resultaat; hem hier uit de invoer
    // halen scheelt een extra rondje naar de database.
    const reasonById = new Map(entries.map((e) => [e.pharmacy_id, e.extra_reason]));
    const rows = ((data ?? []) as ExtraRow[]).map((r) => ({
      ...r, extra_reason: reasonById.get(r.pharmacy_id) ?? null,
    }));

    let mailed = 0, mailSkipped = 0;
    for (const row of rows) {
      const address = (row.billing_email ?? '').trim();
      if (!address) {
        console.warn(`[benu-koerier] ${row.pharmacy_name} heeft geen facturatieadres — geen mail.`);
        mailSkipped++;
        continue;
      }
      const gate = gateFor(address);
      if (!gate.send) {
        console.log(`[benu-koerier] geen mail naar ${address}: ${gate.reason}`);
        mailSkipped++;
        continue;
      }
      if (!BREVO_API_KEY || !MAIL_FROM) {
        console.warn('[benu-koerier] BREVO_API_KEY/MAIL_FROM ontbreken — geen mail verstuurd.');
        mailSkipped++;
        continue;
      }

      const link = BENU_PHARMACY_URL
        ? `${BENU_PHARMACY_URL}?t=${encodeURIComponent(row.pharmacy_token)}`
        : '';
      if (!link) console.warn('[benu-koerier] BENU_PHARMACY_URL ontbreekt — mail zonder reactieknop.');

      const mail = buildPharmacyMail(row, shiftDate, courierName, link);
      try {
        const out = await sendMail(address, row.pharmacy_name, mail.subject, mail.text, mail.html);
        if (out.ok) { mailed++; } else { mailSkipped++; console.error(`[benu-koerier] mail mislukt voor ${row.pharmacy_name}:`, out.error); }
      } catch (e) {
        // De invoer staat er en de termijn loopt; een mislukte mail mag het
        // indienen niet terugdraaien. Loggen en doorgaan.
        mailSkipped++;
        console.error(`[benu-koerier] mail mislukt voor ${row.pharmacy_name}:`, e instanceof Error ? e.message : String(e));
      }
    }

    console.log(`[benu-koerier] ingediend: ${rows.length} apotheek(en) met extra tijd, ${mailed} gemaild, ${mailSkipped} niet.`);
    return json({ ok: true, extra: rows.length, mailed }, 200);
  }

  return json({ error: 'Methode niet toegestaan.' }, 405);
});
