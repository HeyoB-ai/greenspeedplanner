// ════════════════════════════════════════════════════════════════════════
// Greenspeed Planner — BENU: dagelijkse tijdinvoer naar de koerier
// ════════════════════════════════════════════════════════════════════════
// Supabase Edge Function (Deno). Draait 's avonds via een cron-schedule en
// stuurt elke koerier met een BENU selfbilling-dienst van vandaag één mail met
// een link naar zijn invulformulier.
//
// Werkwijze — claim-dan-versturen, met één verschil ten opzichte van de
// SMS-herinnering: er is geen outbox. De claim (benu_claim_shift) is zelf de
// idempotentiesleutel — hij maakt het formulier aan of geeft het bestaande
// token terug, dankzij de UNIQUE op shift_id. Mislukt de mail daarna, dan staat
// het formulier er wél en de link is geldig; de volgende run stuurt hem niet
// opnieuw, want benu_shifts_to_mail() ziet de dienst dan niet meer.
//
// Dat is een bewuste keuze: een gemiste mail kan de planning navragen, een
// dubbele zet een koerier aan het twijfelen of hij al ingediend had.
// ════════════════════════════════════════════════════════════════════════

import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const SUPABASE_URL     = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const BREVO_API_KEY    = Deno.env.get('BREVO_API_KEY') ?? '';
const MAIL_FROM        = Deno.env.get('MAIL_FROM') ?? '';
const MAIL_FROM_NAME   = Deno.env.get('MAIL_FROM_NAME') ?? 'GoBob Planning';
const MAIL_REPLY_TO    = Deno.env.get('MAIL_REPLY_TO') ?? '';
const PLANNING_PHONE   = Deno.env.get('PLANNING_PHONE') ?? '';
const CRON_SECRET      = Deno.env.get('CRON_SECRET') ?? '';

// Waar het koeriersformulier staat. Zonder deze instelling gaat er niets uit:
// een mail met een kapotte link is erger dan een mail die nog niet ging.
const BENU_COURIER_URL = Deno.env.get('BENU_COURIER_URL') ?? '';

// Veiligheidsrem, zelfde gedachte als SMS_MAX_PER_RUN.
const MAX_PER_RUN      = Number(Deno.env.get('BENU_MAX_PER_RUN') ?? '50');

// ── De poort: fail-closed ────────────────────────────────────────────────
// Letterlijk dezelfde regels als send-shift-mail: zonder allowlist gaat er
// NIETS uit, live gaan vergt een aparte MAIL_LIVE=1, en staat er allebei dan
// wint de allowlist — de meest beperkende instelling.
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

// ── Vormen uit de RPC ────────────────────────────────────────────────────
interface BenuPharmacy {
  pharmacy_id: string;
  pharmacy_name: string;
  planned_minutes: number | null;
}

interface BenuShift {
  shift_id: string;
  shift_date: string;          // 'YYYY-MM-DD'
  courier_id: string;
  courier_name: string | null;
  courier_email: string | null;
  pharmacies: BenuPharmacy[];
}

// ── Tekst- en datumhulpjes ───────────────────────────────────────────────
function firstName(full: string): string {
  return full.trim().split(' ')[0] || full;
}

// 'A', 'A en B', 'A, B en C' — leest als een zin.
function joinNames(names: string[]): string {
  if (names.length === 0) return 'de apotheek';
  if (names.length === 1) return names[0];
  return `${names.slice(0, -1).join(', ')} en ${names[names.length - 1]}`;
}

// 'YYYY-MM-DD' → '25-09-2026'. De datum komt als losse getallen binnen, want
// new Date('2026-09-25') is UTC-middernacht en schuift in Amsterdam een dag.
function dateNL(iso: string): string {
  const [y, m, d] = iso.split('-');
  return `${d}-${m}-${y}`;
}

// De vervaldatum van het token: 10:00 Amsterdamse tijd, de ochtend ná de dienst.
// De functie draait in UTC, dus de omrekening moet expliciet. In plaats van een
// vaste -1 of -2 uur (zomertijd!) vragen we de zone zelf wat 10:00 lokaal in UTC
// is: bouw een kandidaat in UTC, kijk hoe Amsterdam die weergeeft, en corrigeer
// met het verschil. Eén ronde is genoeg — de offset verspringt niet binnen het
// uur waar dit op uitkomt.
function nextMorningTenAmsterdam(shiftDateISO: string): string {
  const [y, m, d] = shiftDateISO.split('-').map(Number);
  const next = new Date(Date.UTC(y, m - 1, d + 1, 10, 0, 0));

  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Europe/Amsterdam',
    hour: '2-digit', minute: '2-digit', hour12: false,
  }).formatToParts(next);
  const get = (t: string) => Number(parts.find((p) => p.type === t)?.value ?? '0');

  // Hoeveel wijkt de lokale weergave af van de bedoelde 10:00?
  const shownMinutes = get('hour') * 60 + get('minute');
  const driftMinutes = shownMinutes - 600;
  return new Date(next.getTime() - driftMinutes * 60_000).toISOString();
}

// ── Mailopmaak ───────────────────────────────────────────────────────────
// Zelfde vorm als send-shift-mail: 600px tabel, witte kaart op #f1f5f9, knop in
// #006b5a met bgcolor als attribuut naast de CSS (Outlook strijkt de CSS weg).
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

function closingText(): string {
  return PLANNING_PHONE
    ? `Vragen of verhinderd? Bel de planning: ${PLANNING_PHONE}`
    : 'Vragen of verhinderd? Bel de planning.';
}

function buildMail(s: BenuShift, link: string): { subject: string; text: string; html: string } {
  const names   = s.pharmacies.map((p) => p.pharmacy_name);
  const where   = joinNames(names);
  const hoi     = `Hoi ${firstName(s.courier_name ?? '')},`.replace('Hoi ,', 'Hoi,');
  const subject = `BENU tijdinvoer ${dateNL(s.shift_date)} — vul je PDA-tijden in`;

  const text = [
    hoi,
    '',
    `Kun je de PDA-tijden van vandaag doorgeven voor je dienst bij ${where}?`,
    '',
    'Tijden invullen:',
    link,
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
    `<p style="${PARA}">${esc(hoi)}</p>`,
    `<p style="${PARA}">Kun je de PDA-tijden van vandaag doorgeven voor je dienst bij ${esc(where)}?</p>`,
    // Knop. bgcolor als ATTRIBUUT naast de CSS: alleen de CSS wordt gestript.
    '<table role="presentation" border="0" cellpadding="0" cellspacing="0" style="border-collapse:collapse;margin:0 0 10px 0;">',
    '  <tr>',
    `    <td bgcolor="#006b5a" align="center" style="background-color:#006b5a;border-radius:4px;padding:13px 22px;${FONT}font-size:15px;font-weight:bold;color:#ffffff;">`,
    `      <a href="${esc(link)}" style="${FONT}font-size:15px;font-weight:bold;color:#ffffff;text-decoration:none;">Tijden invullen</a>`,
    '    </td>',
    '  </tr>',
    '</table>',
    // Vangnet: een knop kan sneuvelen bij doorsturen of in tekstweergave.
    // word-break is geen opsmuk — een token van 36 tekens breekt de kolom open.
    `<p style="margin:0 0 16px 0;${FONT}font-size:12px;line-height:18px;color:#64748b;">Werkt de knop niet? Gebruik deze link:<br /><a href="${esc(link)}" style="color:#006b5a;word-break:break-all;">${esc(link)}</a></p>`,
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

// ── Brevo ────────────────────────────────────────────────────────────────
async function sendMail(
  to: string, toName: string, subject: string, text: string, html: string,
): Promise<{ ok: boolean; id?: string; error?: string }> {
  const body: Record<string, unknown> = {
    sender: { name: MAIL_FROM_NAME, email: MAIL_FROM },
    to: [{ email: to, name: toName }],
    subject,
    textContent: text,
    htmlContent: html,
    tags: ['benu-tijdinvoer'],
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

  const raw = await res.text();
  if (!res.ok) return { ok: false, error: `Brevo ${res.status}: ${raw.slice(0, 300)}` };
  try {
    return { ok: true, id: String(JSON.parse(raw).messageId ?? '') };
  } catch {
    return { ok: true };
  }
}

// ── Hoofdlus ─────────────────────────────────────────────────────────────
Deno.serve(async (req) => {
  if (CRON_SECRET && req.headers.get('x-cron-secret') !== CRON_SECRET) {
    return json({ error: 'Niet toegestaan' }, 401);
  }
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
    return json({ error: 'SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY ontbreken' }, 500);
  }

  const url = new URL(req.url);
  const dryRun = url.searchParams.get('dry_run') === '1'
              || (Deno.env.get('MAIL_DRY_RUN') ?? '') === '1';

  if (!dryRun && (!BREVO_API_KEY || !MAIL_FROM)) {
    return json({ error: 'BREVO_API_KEY en/of MAIL_FROM ontbreken' }, 500);
  }
  if (!dryRun && !BENU_COURIER_URL) {
    return json({ error: 'BENU_COURIER_URL ontbreekt — zonder invullink gaat er niets uit' }, 500);
  }

  if (ALLOWLIST.length > 0 && LIVE) {
    console.warn(`[benu] MAIL_LIVE staat aan MAAR er is een allowlist van ${ALLOWLIST.length} adres(sen) — de allowlist wint.`);
  } else if (ALLOWLIST.length === 0 && !LIVE) {
    console.warn('[benu] Geen MAIL_ALLOWLIST en MAIL_LIVE staat niet aan — er wordt NIETS verstuurd.');
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const { data, error } = await admin.rpc('benu_shifts_to_mail');
  if (error) {
    console.error('[benu] benu_shifts_to_mail mislukt:', error.message);
    return json({ error: error.message }, 500);
  }

  const all = (data ?? []) as BenuShift[];
  const due = all.slice(0, MAX_PER_RUN);
  const capped = all.length - due.length;
  if (capped > 0) {
    console.warn(`[benu] ${all.length} diensten, ${MAX_PER_RUN} verwerkt, ${capped} overgeslagen (BENU_MAX_PER_RUN). Zij komen bij de volgende run aan de beurt.`);
  }

  const results: Array<Record<string, unknown>> = [];
  let sent = 0, failed = 0, skipped = 0;

  for (const s of due) {
    const address = (s.courier_email ?? '').trim();
    const names = s.pharmacies.map((p) => p.pharmacy_name);

    if (!address) {
      // Geen adres = geen formulier klaarzetten: dan zou de dienst uit de
      // selectie vallen en er nooit meer een mail over komen.
      console.warn(`[benu] dienst ${s.shift_id}: koerier ${s.courier_name ?? s.courier_id} heeft geen e-mailadres — overgeslagen.`);
      skipped++;
      continue;
    }

    if (dryRun) {
      const { subject } = buildMail(s, `${BENU_COURIER_URL || '<BENU_COURIER_URL>'}?t=<token>`);
      results.push({
        shift: s.shift_id,
        courier: s.courier_name,
        to: address,
        gate: gateFor(address),
        pharmacies: names,
        expires_at: nextMorningTenAmsterdam(s.shift_date),
        subject,
      });
      continue;
    }

    const gate = gateFor(address);
    if (!gate.send) {
      // Niets claimen: de dienst blijft in de selectie, zodat hij alsnog gaat
      // zodra de poort opengaat.
      console.log(`[benu] dienst ${s.shift_id} niet verstuurd naar ${address}: ${gate.reason}`);
      skipped++;
      continue;
    }

    const { data: claimed, error: claimErr } = await admin.rpc('benu_claim_shift', {
      p_shift_id:   s.shift_id,
      p_courier_id: s.courier_id,
      p_pharmacies: s.pharmacies,
      p_expires_at: nextMorningTenAmsterdam(s.shift_date),
    });
    if (claimErr) {
      console.error(`[benu] claim mislukt voor ${s.shift_id}:`, claimErr.message);
      failed++;
      continue;
    }

    const row = Array.isArray(claimed) ? claimed[0] : claimed;
    const token = row?.courier_token ?? '';
    if (!token) {
      console.error(`[benu] claim gaf geen token terug voor ${s.shift_id}`);
      failed++;
      continue;
    }

    const link = `${BENU_COURIER_URL}?t=${encodeURIComponent(token)}`;
    const mail = buildMail(s, link);

    let outcome: { ok: boolean; id?: string; error?: string };
    try {
      outcome = await sendMail(address, s.courier_name ?? '', mail.subject, mail.text, mail.html);
    } catch (e) {
      outcome = { ok: false, error: `Netwerkfout: ${e instanceof Error ? e.message : String(e)}` };
    }

    if (outcome.ok) {
      sent++;
    } else {
      // Geen outbox om dit in weg te schrijven: het formulier staat klaar en de
      // link werkt, maar de koerier weet het niet. Loggen en doorgaan — bij de
      // volgende run valt deze dienst buiten de selectie.
      failed++;
      console.error(`[benu] versturen mislukt voor ${s.shift_id} (${address}):`, outcome.error);
    }
    results.push({ shift: s.shift_id, courier: s.courier_name, ok: outcome.ok, error: outcome.error });
  }

  const summary = {
    dry_run: dryRun,
    mode: ALLOWLIST.length > 0 ? `allowlist (${ALLOWLIST.length})` : (LIVE ? 'live' : 'dicht — niets gaat uit'),
    due: all.length,
    processed: due.length,
    capped,
    sent,
    failed,
    skipped,
    results: dryRun ? results : undefined,
  };
  console.log('[benu]', JSON.stringify({ ...summary, results: undefined }));
  return json(summary, 200);
});

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status, headers: { 'Content-Type': 'application/json' },
  });
}
