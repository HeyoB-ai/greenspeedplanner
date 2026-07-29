// ════════════════════════════════════════════════════════════════════════
// Greenspeed Planner — herinnerings-SMS, 24 uur vóór aanvang
// ════════════════════════════════════════════════════════════════════════
// Supabase Edge Function (Deno). Draait elk uur via een cron-schedule; zie de
// README voor het opzetten daarvan.
//
// Werkwijze — claim-dan-versturen:
//   1. sms_due_shifts()   → alles wat binnen het venster begint, nog in de
//                           toekomst ligt en nog geen logrij heeft.
//   2. sms_claim_shift()  → logrij wegschrijven. Geeft false als een andere run
//                           hem al had → overslaan. Dit is de idempotentie.
//   3. Brevo aanroepen.
//   4. sms_record_result()→ uitkomst terugschrijven ('sent' of 'failed').
//
// Crasht het proces tussen 2 en 3, dan blijft de rij op 'sending' staan en gaat
// er géén bericht meer uit voor die dienst. Bewust: een gemiste SMS die je in
// het weekoverzicht ziet is goedkoper dan een dubbele bij de koerier.
//
// Slaat een run over, dan haalt de volgende hem in — de selectie is een sweep,
// geen strak venster. Alleen diensten die intussen al begonnen zijn vallen af.
// ════════════════════════════════════════════════════════════════════════

import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const SUPABASE_URL      = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_ROLE_KEY  = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const BREVO_API_KEY     = Deno.env.get('BREVO_API_KEY') ?? '';
const SMS_SENDER        = Deno.env.get('SMS_SENDER') ?? 'Greenspeed';
const WINDOW_HOURS      = Number(Deno.env.get('SMS_WINDOW_HOURS') ?? '24');
const CRON_SECRET       = Deno.env.get('CRON_SECRET') ?? '';
// Veiligheidsrem: bij een verkeerd gezet venster (of de allereerste run met een
// volle agenda) niet ongemerkt honderden berichten sturen.
const MAX_PER_RUN       = Number(Deno.env.get('SMS_MAX_PER_RUN') ?? '50');

interface DueShift {
  shift_id: string;
  courier_id: string;
  courier_name: string;
  phone_e164: string;
  start_at: string;            // ISO, timestamptz
  shift_date: string;
  start_time: string;
  budgeted_end_time: string | null;
  pharmacy_names: string[];
}

// ── Berichttekst ─────────────────────────────────────────────────────────
// VOORLOPIG — de definitieve tekst is nog niet vastgesteld. Dit is de enige
// plek waar hij staat; aanpassen kan zonder de rest te raken.
//
// Randvoorwaarden die wél vastliggen:
//   * Eén SMS-segment is 160 tekens in GSM-7. Eén accent (é, ï) zet het hele
//     bericht om naar Unicode en dan is het 70 per segment — vandaar dat we
//     accenten weghalen in plaats van erop te hopen.
//   * Geen patiëntgegevens.
//   * De afzender is alfanumeriek, dus de koerier kan niet terug-sms'en. Dat
//     moet in de tekst staan, anders sms't iemand terug het niets in.
function buildMessage(s: DueShift): string {
  const when = formatWhen(s.start_at);
  const where = s.pharmacy_names.length > 0 ? s.pharmacy_names.join(' + ') : 'de apotheek';
  const text = `Greenspeed: dienst ${when} bij ${where}. Vragen of verhinderd? Bel de planning. Niet antwoorden op deze sms.`;
  return truncate(toGsm7(text), 160);
}

// 'di 12-08 07:45' in Nederlandse tijd. De starttijd staat als lokale tijd in de
// database en is in SQL al naar timestamptz omgerekend; hier zetten we hem weer
// bewust in Europe/Amsterdam om, want de functie zelf draait in UTC.
function formatWhen(startAtISO: string): string {
  const d = new Date(startAtISO);
  const parts = new Intl.DateTimeFormat('nl-NL', {
    timeZone: 'Europe/Amsterdam',
    weekday: 'short', day: '2-digit', month: '2-digit',
    hour: '2-digit', minute: '2-digit', hour12: false,
  }).formatToParts(d);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? '';
  const weekday = get('weekday').replace('.', '');
  return `${weekday} ${get('day')}-${get('month')} ${get('hour')}:${get('minute')}`;
}

// Accenten en typografische tekens terugbrengen tot GSM-7-veilige ASCII, zodat
// het bericht in één segment past. Apotheeknamen zijn de voornaamste bron.
function toGsm7(s: string): string {
  return s
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')  // losse accenttekens weghalen
    .replace(/[\u2018\u2019\u201a]/g, "'")
    .replace(/[\u201c\u201d\u201e]/g, '"')
    .replace(/[\u2013\u2014]/g, '-')
    .replace(/\u00a0/g, ' ')          // harde spatie
    .replace(/\u2026/g, '...');
}

function truncate(s: string, max: number): string {
  return s.length <= max ? s : `${s.slice(0, max - 1)}.`;
}

// ── Brevo ────────────────────────────────────────────────────────────────
// Transactionele SMS: https://api.brevo.com/v3/transactionalSMS/send
// 'recipient' wil het nummer zonder '+' (landcode + nummer).
async function sendSms(phoneE164: string, content: string): Promise<{ ok: boolean; id?: string; error?: string }> {
  const res = await fetch('https://api.brevo.com/v3/transactionalSMS/send', {
    method: 'POST',
    headers: {
      'api-key': BREVO_API_KEY,
      'Content-Type': 'application/json',
      'Accept': 'application/json',
    },
    body: JSON.stringify({
      sender: SMS_SENDER,
      recipient: phoneE164.replace(/^\+/, ''),
      content,
      type: 'transactional',
      tag: 'dienstherinnering',
    }),
  });

  const body = await res.text();
  if (!res.ok) {
    return { ok: false, error: `Brevo ${res.status}: ${body.slice(0, 300)}` };
  }
  try {
    const json = JSON.parse(body);
    return { ok: true, id: String(json.messageId ?? json.reference ?? '') };
  } catch {
    return { ok: true };
  }
}

// ── Hoofdlus ─────────────────────────────────────────────────────────────
Deno.serve(async (req) => {
  // Extra slot bovenop de JWT-controle van Supabase: als CRON_SECRET gezet is,
  // moet de aanroeper hem meesturen. Zo kan een geldig maar ongerelateerd token
  // deze functie niet triggeren.
  if (CRON_SECRET && req.headers.get('x-cron-secret') !== CRON_SECRET) {
    return json({ error: 'Niet toegestaan' }, 401);
  }

  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
    return json({ error: 'SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY ontbreken' }, 500);
  }

  // Losse schakelaar om te proefdraaien: haalt op en stelt de berichten samen,
  // maar claimt niets en verstuurt niets. Bedoeld voor de eerste keer — dan zie
  // je precies wie er een bericht zou krijgen voordat het echt gebeurt.
  const url = new URL(req.url);
  const dryRun = url.searchParams.get('dry_run') === '1'
              || (Deno.env.get('SMS_DRY_RUN') ?? '') === '1';

  if (!dryRun && !BREVO_API_KEY) {
    return json({ error: 'BREVO_API_KEY ontbreekt' }, 500);
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const { data, error } = await admin.rpc('sms_due_shifts', { p_window_hours: WINDOW_HOURS });
  if (error) {
    console.error('[sms] sms_due_shifts mislukt:', error.message);
    return json({ error: error.message }, 500);
  }

  const all = (data ?? []) as DueShift[];
  const due = all.slice(0, MAX_PER_RUN);
  // Nooit stilzwijgend afkappen: als de rem ingrijpt moet dat in de logs staan.
  const capped = all.length - due.length;
  if (capped > 0) {
    console.warn(`[sms] ${all.length} diensten in het venster, ${MAX_PER_RUN} verwerkt, ${capped} overgeslagen (SMS_MAX_PER_RUN). Zij komen bij de volgende run aan de beurt.`);
  }

  const results: Array<Record<string, unknown>> = [];
  let sent = 0, failed = 0, skipped = 0;

  for (const s of due) {
    const content = buildMessage(s);

    if (dryRun) {
      results.push({ shift: s.shift_id, courier: s.courier_name, to: s.phone_e164, content });
      continue;
    }

    const { data: claimed, error: claimErr } = await admin.rpc('sms_claim_shift', {
      p_shift_id: s.shift_id, p_courier_id: s.courier_id, p_phone: s.phone_e164,
    });
    if (claimErr) {
      console.error(`[sms] claim mislukt voor ${s.shift_id}:`, claimErr.message);
      failed++;
      continue;
    }
    if (claimed !== true) {
      // Andere run was ons voor. Precies wat de sleutel moet doen.
      skipped++;
      continue;
    }

    let outcome: { ok: boolean; id?: string; error?: string };
    try {
      outcome = await sendSms(s.phone_e164, content);
    } catch (e) {
      outcome = { ok: false, error: `Netwerkfout: ${e instanceof Error ? e.message : String(e)}` };
    }

    const { error: recErr } = await admin.rpc('sms_record_result', {
      p_shift_id: s.shift_id,
      p_ok: outcome.ok,
      p_message_id: outcome.id ?? null,
      p_error: outcome.error ?? null,
    });
    if (recErr) {
      // Het bericht is dan wél de deur uit maar de log staat nog op 'sending'.
      // Loggen en doorgaan: opnieuw versturen zou een dubbele opleveren.
      console.error(`[sms] resultaat wegschrijven mislukt voor ${s.shift_id}:`, recErr.message);
    }

    if (outcome.ok) { sent++; } else { failed++; console.error(`[sms] versturen mislukt voor ${s.shift_id}:`, outcome.error); }
    results.push({ shift: s.shift_id, courier: s.courier_name, ok: outcome.ok, error: outcome.error });
  }

  const summary = {
    dry_run: dryRun,
    window_hours: WINDOW_HOURS,
    due: all.length,
    processed: due.length,
    capped,
    sent,
    failed,
    skipped,
    results: dryRun ? results : undefined,
  };
  console.log('[sms]', JSON.stringify({ ...summary, results: undefined }));
  return json(summary, 200);
});

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status, headers: { 'Content-Type': 'application/json' },
  });
}
