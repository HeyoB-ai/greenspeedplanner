// ════════════════════════════════════════════════════════════════════════
// Greenspeed Planner — bevestigingsmail: de verzendkant
// ════════════════════════════════════════════════════════════════════════
// Supabase Edge Function (Deno). Leest mail_outbox, bundelt per koerier en
// verstuurt via Brevo. Het ontwerp staat in docs/FASE5_MAIL_ONTWERP.md.
//
// Werkwijze per koerier — adres eerst, dan claimen:
//   1. mail_pending_couriers()  → wie heeft er post klaarstaan
//   2. mail_recipient_for()     → welk adres (override vóór inlogadres)
//   3. allowlist-poort          → mag er naar dit adres gestuurd worden
//   4. mail_claim_for_courier() → alle wachtende berichten in één UPDATE naar
//                                 'sending'; een tweede verzender krijgt nul rijen
//   5. Brevo aanroepen met één gebundelde mail
//   6. mail_record_result()     → 'sent' of 'failed' op de hele bundel
//
// Die volgorde is met opzet: is er geen adres of staat het niet op de allowlist,
// dan wordt er NIET geclaimd. De berichten blijven op 'pending' staan en gaan
// gewoon mee zodra het adres er is of de allowlist eraf gaat. Zou je eerst
// claimen, dan zou zo'n bundel als mislukt eindigen en nooit meer uitgaan.
//
// Crasht het proces tussen claimen en versturen, dan blijft de bundel op
// 'sending' staan en gaat er niets meer uit — fail-closed en zichtbaar in de
// outbox, dezelfde keuze als bij de SMS.
// ════════════════════════════════════════════════════════════════════════

import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const SUPABASE_URL     = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const BREVO_API_KEY    = Deno.env.get('BREVO_API_KEY') ?? '';
const MAIL_FROM        = Deno.env.get('MAIL_FROM') ?? '';
const MAIL_FROM_NAME   = Deno.env.get('MAIL_FROM_NAME') ?? 'Greenspeed Planning';
const MAIL_REPLY_TO    = Deno.env.get('MAIL_REPLY_TO') ?? '';
const CRON_SECRET      = Deno.env.get('CRON_SECRET') ?? '';
const MAX_PER_RUN      = Number(Deno.env.get('MAIL_MAX_PER_RUN') ?? '25');

// Zolang het testdomein in gebruik is: alleen naar deze adressen. Leeg betekent
// géén beperking — dat is de bewuste stap "we gaan live", en de functie zegt dat
// bij elke run in de logs zodat het niet per ongeluk zo blijft staan.
const ALLOWLIST = (Deno.env.get('MAIL_ALLOWLIST') ?? '')
  .split(',').map((s) => s.trim().toLowerCase()).filter(Boolean);

function isAllowed(address: string): boolean {
  return ALLOWLIST.length === 0 || ALLOWLIST.includes(address.toLowerCase());
}

// ── Vormen uit de outbox ─────────────────────────────────────────────────
interface PayloadShift {
  shift_date: string;                  // 'YYYY-MM-DD'
  weekday: number;                     // ISO 1=maandag
  start_time: string;                  // 'HH:MM'
  budgeted_end_time: string | null;
  transport_mode: 'bike' | 'car';
  pharmacies: string[];
}

interface OutboxRow {
  id: string;
  courier_id: string;
  kind: string;
  subject_type: string | null;
  subject_id: string | null;
  payload: {
    subject_type?: string;
    courier_name?: string;
    end_date?: string | null;
    shifts?: PayloadShift[];
    // alleen bij een afmelding: de gegevens van de verdwenen dienst
    shift_date?: string;
    weekday?: number;
    start_time?: string;
    budgeted_end_time?: string | null;
    transport_mode?: 'bike' | 'car';
    pharmacies?: string[];
    reason?: string;
  };
  created_at: string;
}

// ── Tekst ────────────────────────────────────────────────────────────────
// Geen accenttekens, kort, en per blok duidelijk wat de koerier moet doen of
// weten. Dit is de enige plek waar de tekst staat.

const WEEKDAYS = ['maandag', 'dinsdag', 'woensdag', 'donderdag', 'vrijdag', 'zaterdag', 'zondag'];

// 'YYYY-MM-DD' → '30-07-2026'. Puur op de string, dus geen tijdzone die
// een datum een dag kan verschuiven.
function fmtDate(iso: string): string {
  const [y, m, d] = iso.split('-');
  return `${d}-${m}-${y}`;
}

function dayName(isoDow: number): string {
  return WEEKDAYS[isoDow - 1] ?? 'dag';
}

function fmtTime(start: string, end: string | null | undefined): string {
  return end ? `${start}-${end}` : start;
}

function transportText(mode: string | undefined): string {
  return mode === 'car' ? 'met de auto' : 'met de fiets';
}

function joinNames(names: string[] | undefined): string {
  if (!names || names.length === 0) return 'de apotheek';
  if (names.length === 1) return names[0];
  return `${names.slice(0, -1).join(', ')} en ${names[names.length - 1]}`;
}

// Eén dienst als losse regel: 'donderdag 30-07-2026, 19:12-21:00 bij X, met de fiets'
function describeShift(s: PayloadShift): string {
  return `${dayName(s.weekday)} ${fmtDate(s.shift_date)}, ${fmtTime(s.start_time, s.budgeted_end_time)}`
       + ` bij ${joinNames(s.pharmacies)}, ${transportText(s.transport_mode)}`;
}

interface Variant { shift: PayloadShift; first: string; last: string }

// Diensten samenvouwen tot varianten. Staan er twee tijden bevestigd (na een
// wijziging waarvan een deel bevestigd is), dan zijn dat twee varianten en
// worden ze beide genoemd — met hun ingangsdatum, want de oude staat nog
// bevestigd en daar wordt de koerier volgende week op verwacht.
function groupVariants(shifts: PayloadShift[]): Variant[] {
  const byKey = new Map<string, Variant>();
  for (const s of shifts) {
    const key = [s.weekday, s.start_time, s.budgeted_end_time ?? '-', s.transport_mode,
                 [...(s.pharmacies ?? [])].sort().join(',')].join('|');
    const found = byKey.get(key);
    if (!found) {
      byKey.set(key, { shift: s, first: s.shift_date, last: s.shift_date });
    } else {
      if (s.shift_date < found.first) found.first = s.shift_date;
      if (s.shift_date > found.last) found.last = s.shift_date;
    }
  }
  return [...byKey.values()].sort((a, b) => (a.first < b.first ? -1 : 1));
}

function variantLines(shifts: PayloadShift[]): string[] {
  const variants = groupVariants(shifts);
  return variants.map((v, i) => {
    const base = `elke ${dayName(v.shift.weekday)} ${fmtTime(v.shift.start_time, v.shift.budgeted_end_time)}`
               + ` bij ${joinNames(v.shift.pharmacies)}, ${transportText(v.shift.transport_mode)}`;
    // De laatste variant loopt door; de eerdere worden afgebakend, zodat de
    // overgang tussen twee tijden ondubbelzinnig is.
    const period = i === variants.length - 1
      ? `vanaf ${fmtDate(v.first)}`
      : `van ${fmtDate(v.first)} t/m ${fmtDate(v.last)}`;
    return `- ${base}, ${period}`;
  });
}

// Eén blok per feit uit de outbox. Zonder aanhef en zonder afsluiting: die zet
// de bundelaar er één keer om heen.
function renderBlock(row: OutboxRow): string[] {
  const p = row.payload;
  const shifts = p.shifts ?? [];

  switch (row.kind) {
    case 'schedule_confirmed': {
      if (shifts.length === 0) return [];
      const lines = ['Je staat vast ingepland:', ...variantLines(shifts)];
      if (p.end_date) lines.push(`Deze afspraak loopt t/m ${fmtDate(p.end_date)}.`);
      return lines;
    }
    case 'schedule_changed': {
      if (shifts.length === 0) return [];
      const lines = ['Je vaste dienst is gewijzigd. Dit staat er nu:', ...variantLines(shifts)];
      if (p.end_date) lines.push(`Deze afspraak loopt t/m ${fmtDate(p.end_date)}.`);
      return lines;
    }
    case 'shift_confirmed': {
      if (shifts.length === 0) return [];
      if (shifts.length === 1) return [`Je bent ingepland op ${describeShift(shifts[0])}.`];
      return ['Je bent ingepland op:', ...shifts.map((s) => `- ${describeShift(s)}`)];
    }
    case 'shift_changed': {
      if (shifts.length === 0) return [];
      if (shifts.length === 1) return [`Je dienst is gewijzigd. Dit staat er nu: ${describeShift(shifts[0])}.`];
      return ['Je diensten zijn gewijzigd. Dit staat er nu:', ...shifts.map((s) => `- ${describeShift(s)}`)];
    }
    case 'shift_cancelled': {
      if (!p.shift_date || !p.start_time) return [];
      const what = `${dayName(p.weekday ?? 1)} ${fmtDate(p.shift_date)}, ${fmtTime(p.start_time, p.budgeted_end_time)}`
                 + ` bij ${joinNames(p.pharmacies)}`;
      const head = p.reason === 'andere koerier'
        ? `Deze dienst gaat naar een andere koerier: ${what}.`
        : `Deze dienst vervalt: ${what}.`;
      return [`${head} Je hoeft niet te komen.`];
    }
    case 'schedule_cancelled': {
      // Nog niet in gebruik (zie de CHECK in migratie 016); hier alvast een
      // leesbare vorm zodat een onbekend feit nooit een lege mail oplevert.
      const what = p.pharmacies ? ` bij ${joinNames(p.pharmacies)}` : '';
      return [`Je vaste dienst${what} komt te vervallen. Je hoeft niet meer te komen.`];
    }
    default:
      return [];
  }
}

function subjectFor(rows: OutboxRow[]): string {
  if (rows.length > 1) return 'Je planning is bijgewerkt';
  const row = rows[0];
  const p = row.payload;
  const when = p.shift_date
    ? `${dayName(p.weekday ?? 1)} ${fmtDate(p.shift_date)}`
    : (p.shifts && p.shifts.length > 0 ? `${dayName(p.shifts[0].weekday)} ${fmtDate(p.shifts[0].shift_date)}` : '');
  switch (row.kind) {
    case 'schedule_confirmed': return 'Je vaste dienst staat vast';
    case 'schedule_changed':   return 'Je vaste dienst is gewijzigd';
    case 'schedule_cancelled': return 'Je vaste dienst vervalt';
    case 'shift_confirmed':    return when ? `Je bent ingepland op ${when}` : 'Je bent ingepland';
    case 'shift_changed':      return when ? `Je dienst van ${when} is gewijzigd` : 'Je dienst is gewijzigd';
    case 'shift_cancelled':
      if (p.reason === 'andere koerier') {
        return when ? `Je dienst van ${when} gaat naar een andere koerier` : 'Je dienst gaat naar een andere koerier';
      }
      return when ? `Je dienst van ${when} vervalt` : 'Je dienst vervalt';
    default:                   return 'Bericht over je planning';
  }
}

// De volledige mail. Feiten in de volgorde waarin ze ontstonden: bij een
// verzetting staat "vervalt" dan boven "je staat nu op", zoals het gebeurd is.
function renderMail(rows: OutboxRow[], courierName: string): { subject: string; text: string } | null {
  const blocks = rows
    .slice()
    .sort((a, b) => (a.created_at < b.created_at ? -1 : 1))
    .map(renderBlock)
    .filter((b) => b.length > 0);

  if (blocks.length === 0) return null;

  const body = blocks.map((b) => b.join('\n')).join('\n\n');
  return {
    subject: subjectFor(rows),
    text: `Hoi ${courierName},\n\n${body}\n\nVragen of verhinderd? Bel de planning.\n`,
  };
}

// ── Brevo ────────────────────────────────────────────────────────────────
async function sendMail(
  to: string, toName: string, subject: string, text: string,
): Promise<{ ok: boolean; id?: string; error?: string }> {
  const body: Record<string, unknown> = {
    sender: { name: MAIL_FROM_NAME, email: MAIL_FROM },
    to: [{ email: to, name: toName }],
    subject,
    textContent: text,
    tags: ['dienstbevestiging'],
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
  if (ALLOWLIST.length === 0) {
    console.warn('[mail] GEEN MAIL_ALLOWLIST gezet — er wordt naar alle koeriers verstuurd.');
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const { data: pending, error: pendErr } = await admin.rpc('mail_pending_couriers');
  if (pendErr) {
    console.error('[mail] mail_pending_couriers mislukt:', pendErr.message);
    return json({ error: pendErr.message }, 500);
  }

  const all = (pending ?? []) as Array<{ courier_id: string; courier_name: string; items: number }>;
  const batch = all.slice(0, MAX_PER_RUN);
  const capped = all.length - batch.length;
  if (capped > 0) {
    console.warn(`[mail] ${all.length} koeriers met post, ${MAX_PER_RUN} verwerkt, ${capped} volgende run.`);
  }

  let sent = 0, failed = 0, skipped = 0, empty = 0;
  const results: Array<Record<string, unknown>> = [];

  for (const c of batch) {
    // 1. Adres bepalen — override vóór inlogadres.
    const { data: recips, error: recErr } = await admin.rpc('mail_recipient_for', { p_courier_id: c.courier_id });
    const recip = Array.isArray(recips) ? recips[0] : recips;
    const address: string | null = recErr ? null : (recip?.email ?? null);

    if (!address) {
      // Niet claimen: zodra er een adres is, gaat de post gewoon mee.
      console.warn(`[mail] ${c.courier_name}: geen e-mailadres, ${c.items} bericht(en) blijven wachten.`);
      skipped++;
      results.push({ courier: c.courier_name, skipped: 'geen adres', items: c.items });
      continue;
    }

    // 2. Allowlist-poort — óók niet claimen, zodat de post uitgaat zodra de
    //    beperking eraf is.
    if (!isAllowed(address)) {
      console.log(`[mail] ${c.courier_name} <${address}>: niet op MAIL_ALLOWLIST, ${c.items} bericht(en) blijven wachten.`);
      skipped++;
      results.push({ courier: c.courier_name, skipped: 'niet op allowlist', to: address, items: c.items });
      continue;
    }

    if (recip?.confirmed === false) {
      console.warn(`[mail] ${c.courier_name} <${address}>: adres is nooit bevestigd — mogelijk onbezorgbaar.`);
    }

    // 3. Dry run: lezen zonder claimen, zodat je de tekst kunt beoordelen.
    let rows: OutboxRow[];
    if (dryRun) {
      const { data } = await admin.from('mail_outbox').select('*')
        .eq('courier_id', c.courier_id).eq('status', 'pending');
      rows = (data ?? []) as OutboxRow[];
    } else {
      const { data, error: claimErr } = await admin.rpc('mail_claim_for_courier', { p_courier_id: c.courier_id });
      if (claimErr) {
        console.error(`[mail] claim mislukt voor ${c.courier_name}:`, claimErr.message);
        failed++;
        continue;
      }
      rows = (data ?? []) as OutboxRow[];
      if (rows.length === 0) { skipped++; continue; }  // andere verzender was ons voor
    }
    if (rows.length === 0) continue;

    // 4. Tekst opbouwen.
    const courierName = rows[0].payload?.courier_name ?? c.courier_name;
    const mail = renderMail(rows, courierName);

    if (!mail) {
      // Geen enkel feit leverde inhoud op. Dat wordt nooit beter, dus niet
      // eindeloos opnieuw proberen: als mislukt vastleggen met de reden erbij.
      empty++;
      if (!dryRun) {
        await admin.rpc('mail_record_result', {
          p_ids: rows.map((r) => r.id), p_ok: false, p_recipient: address,
          p_error: 'geen inhoud om te versturen (payload zonder diensten)',
        });
      }
      console.error(`[mail] ${c.courier_name}: ${rows.length} bericht(en) zonder inhoud.`);
      continue;
    }

    if (dryRun) {
      results.push({
        courier: courierName, to: address, source: recip?.source,
        items: rows.length, kinds: rows.map((r) => r.kind),
        subject: mail.subject, text: mail.text,
      });
      continue;
    }

    // 5. Versturen en 6. vastleggen.
    let outcome: { ok: boolean; id?: string; error?: string };
    try {
      outcome = await sendMail(address, courierName, mail.subject, mail.text);
    } catch (e) {
      outcome = { ok: false, error: `Netwerkfout: ${e instanceof Error ? e.message : String(e)}` };
    }

    const { error: recordErr } = await admin.rpc('mail_record_result', {
      p_ids: rows.map((r) => r.id),
      p_ok: outcome.ok,
      p_recipient: address,
      p_message_id: outcome.id ?? null,
      p_error: outcome.error ?? null,
    });
    if (recordErr) {
      // De mail is dan wél de deur uit maar de bundel staat nog op 'sending'.
      // Loggen en doorgaan: opnieuw versturen zou een dubbele opleveren.
      console.error(`[mail] resultaat wegschrijven mislukt voor ${c.courier_name}:`, recordErr.message);
    }

    if (outcome.ok) {
      sent++;
    } else {
      failed++;
      console.error(`[mail] versturen mislukt voor ${c.courier_name}:`, outcome.error);
    }
    results.push({ courier: courierName, to: address, items: rows.length, ok: outcome.ok, error: outcome.error });
  }

  const summary = {
    dry_run: dryRun,
    allowlist: ALLOWLIST.length > 0 ? ALLOWLIST.length : 'geen (alles gaat uit)',
    couriers_with_mail: all.length,
    processed: batch.length,
    capped, sent, failed, skipped, empty,
    results: dryRun ? results : undefined,
  };
  console.log('[mail]', JSON.stringify({ ...summary, results: undefined }));
  return json(summary, 200);
});

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}
