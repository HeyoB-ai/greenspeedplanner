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

// Waar de invulpagina van de nadeclaratie staat (fase 6). Zonder deze instelling
// kan er geen bruikbare link in een nabericht en blijven die berichten wachten —
// een mail met een kapotte link is erger dan een mail die nog niet ging.
const DECLARATION_URL  = Deno.env.get('DECLARATION_URL') ?? '';

// Waar de meerwerkpagina voor apotheken staat (fase 9). Zelfde afweging als
// hierboven: zonder deze instelling gaat er geen bericht uit met een kapotte
// link, maar blijft het wachten.
const EXTRA_WORK_URL   = Deno.env.get('EXTRA_WORK_URL') ?? '';

// ── De poort: fail-closed ────────────────────────────────────────────────
// Bij de SMS zat de bescherming in de data: alleen ingevoerde nummers konden
// bereikt worden, en die voerde de planner zelf in. Bij mail heeft élke koerier
// al een adres in auth.users, dus het enige vangnet is configuratie. Een vergeten
// of verkeerd getypt secret zou dan betekenen dat alles uitgaat.
//
// Daarom: zonder allowlist gaat er NIETS uit. Live gaan vergt een aparte,
// expliciete MAIL_LIVE=1 — losgekoppeld van de allowlist, zodat "leeg" nooit per
// ongeluk "naar iedereen" betekent.
const ALLOWLIST = (Deno.env.get('MAIL_ALLOWLIST') ?? '')
  .split(',').map((s) => s.trim().toLowerCase()).filter(Boolean);
const LIVE = (Deno.env.get('MAIL_LIVE') ?? '') === '1';

// Staat er zowel een allowlist als MAIL_LIVE, dan wint de allowlist: de meest
// beperkende instelling. Iemand die live gaat en vergeet de allowlist te wissen,
// verstuurt dan te weinig in plaats van te veel — en ziet dat in de logs.
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
    // alleen bij een nabericht (shift_followup)
    declaration_id?: string;
    own_car?: boolean;
    // alleen bij een meerwerkmelding (extra_work_request)
    extra_work_id?: string;
    pharmacy_name?: string;
    planned_start?: string;
    planned_end?: string;
    extra_minutes?: number;
    respond_hours?: number;
    // true bij een keten met de factuursplitsing aan: dan komt déze tijd op
    // de eigen factuur van het filiaal en niet op die van de keten.
    own_invoice?: boolean;
    note?: string;
  };
  created_at: string;
  // Geen kolom maar een werkveld: de invullink wordt vlak vóór het renderen
  // gemaakt en bestaat alleen tijdens deze run. Zie de hoofdlus.
  link?: string;
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

// De peildatum boven het bericht, in Nederlandse tijd — de functie draait in UTC.
function todayNL(): string {
  const parts = new Intl.DateTimeFormat('nl-NL', {
    timeZone: 'Europe/Amsterdam', day: '2-digit', month: '2-digit', year: 'numeric',
  }).formatToParts(new Date());
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? '';
  return `${get('day')}-${get('month')}-${get('year')}`;
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

// Elke regel begint met de datum waarop hij ingaat, en noemt NOOIT wanneer iets
// ophoudt. Een einddatum is een uitspraak over de toekomst, en die kan stil
// onwaar worden: de vingerafdruk bevat bewust geen datums (punt 5 van het
// ontwerp), dus een later bevestigde dienst op de oude tijd levert géén nieuwe
// mail op. Met alleen ingangsdatums plus de peildatum bovenaan het bericht is
// zo'n mail hooguit onvolledig in plaats van onwaar.
function variantLines(shifts: PayloadShift[]): string[] {
  return groupVariants(shifts).map((v) =>
    `- vanaf ${fmtDate(v.first)}: elke ${dayName(v.shift.weekday)}`
    + ` ${fmtTime(v.shift.start_time, v.shift.budgeted_end_time)}`
    + ` bij ${joinNames(v.shift.pharmacies)}, ${transportText(v.shift.transport_mode)}`);
}

// Eén blok per feit uit de outbox. Zonder aanhef en zonder afsluiting: die zet
// de bundelaar er één keer om heen.
// p_expected_hours komt uit declaration_settings (migratie 021) en niet uit een
// getal hier: de termijn is een instelling, en twee plekken die 48 zeggen lopen
// vroeg of laat uiteen. Is hij onbekend, dan blijft de zin gewoon weg.
function renderBlock(row: OutboxRow, expectedHours: number | null): string[] {
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
    case 'shift_followup': {
      // Zonder werkende link heeft dit blok geen zin: dan liever niets sturen en
      // het bericht laten wachten tot de link er wel is.
      if (!row.link || !p.shift_date || !p.start_time) return [];
      const what = `${dayName(p.weekday ?? 1)} ${fmtDate(p.shift_date)}, ${fmtTime(p.start_time, p.budgeted_end_time)}`
                 + ` bij ${joinNames(p.pharmacies)}`;
      const lines = [
        `Je dienst van ${what} zit erop. Wil je doorgeven hoe lang hij werkelijk duurde?`,
        row.link,
      ];
      if (p.own_car) {
        // De vraagstelling staat hier en op de pagina in exact dezelfde woorden.
        // Zonder die definitie telt de een de bezorgroute mee en de ander niet,
        // en zijn de opgaves achteraf niet met elkaar te vergelijken.
        lines.push('Reed je op eigen kosten? Geef dan ook de totaal gereden kilometers op,'
                 + ' vanaf vertrek thuis tot terugkomst thuis.');
      }
      if (expectedHours) {
        // Nadrukkelijk een verwachting en geen deadline, en de tweede zin is
        // geen beleefdheid: een koerier die denkt dat hij te laat is vult
        // helemaal niets meer in, en dan zijn we de opgave kwijt in plaats van
        // dat hij laat is.
        lines.push(`Fijn als je dit binnen ${expectedHours} uur na je dienst doorgeeft.`
                 + ' Later invullen kan ook, de link blijft gewoon werken.');
      }
      return lines;
    }
    case 'extra_work_request': {
      // Zonder werkende link heeft dit blok geen zin; het bericht blijft dan
      // wachten in plaats van half uit te gaan.
      if (!row.link || !p.shift_date) return [];
      const when = `${dayName(p.weekday ?? 1)} ${fmtDate(p.shift_date)}`;
      const planned = p.planned_start && p.planned_end
        ? ` (gepland ${p.planned_start}-${p.planned_end})` : '';
      const minutes = Math.round(Number(p.extra_minutes ?? 0));
      const lines = [
        `De dienst van ${when}${planned} duurde ${minutes} minuten langer dan gepland.`,
      ];
      if (p.note) lines.push(`Toelichting: ${p.note}`);
      lines.push('Ga je akkoord met het doorbelasten van die extra tijd?');
      if (p.own_invoice) {
        // Zonder deze zin denkt de lezer aan de factuur die hij van zijn keten
        // kent, en dat is precies de factuur waar dit NIET op komt.
        lines.push('Deze tijd komt op de factuur van dit filiaal, niet op die van de keten.');
      }
      lines.push(row.link);
      lines.push(`Zonder reactie binnen ${p.respond_hours ?? 48} uur belasten we de extra tijd door.`);
      return lines;
    }
    default:
      return [];
  }
}

function subjectFor(rows: OutboxRow[]): string {
  if (rows.length > 1) {
    // Een bundel die alléén uit naberichten bestaat gaat niet over de planning.
    if (rows.every((r) => r.kind === 'shift_followup')) return 'Hoe lang duurden je diensten?';
    if (rows.every((r) => r.kind === 'extra_work_request')) return 'Extra tijd — graag je akkoord';
    return 'Je planning is bijgewerkt';
  }
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
    case 'shift_followup':
      return when ? `Hoe lang duurde je dienst van ${when}?` : 'Hoe lang duurde je dienst?';
    case 'extra_work_request':
      return when ? `Extra tijd op ${when} — graag je akkoord` : 'Extra tijd — graag je akkoord';
    default:                   return 'Bericht over je planning';
  }
}

// De volledige mail. Feiten in de volgorde waarin ze ontstonden: bij een
// verzetting staat "vervalt" dan boven "je staat nu op", zoals het gebeurd is.
//
// Bovenaan staat een PEILDATUM, en dat is geen opsmuk. Alles onder die regel is
// een momentopname, en daarmee permanent waar: verandert er later iets zonder dat
// het een bericht oplevert — wat kan, want de vingerafdruk kent geen datums — dan
// is deze mail onvolledig in plaats van onwaar. Dat is een veel goedkopere fout,
// en het is de enige manier om ook het rommelige geval te dekken waarin twee
// tijden door elkaar heen lopen.
function renderMail(
  rows: OutboxRow[], name: string, expectedHours: number | null,
  audience: 'courier' | 'pharmacy' = 'courier',
): { subject: string; text: string } | null {
  const blocks = rows
    .slice()
    .sort((a, b) => (a.created_at < b.created_at ? -1 : 1))
    .map((r) => renderBlock(r, expectedHours))
    .filter((b) => b.length > 0);

  if (blocks.length === 0) return null;

  const body = blocks.map((b) => b.join('\n')).join('\n\n');
  // Een apotheek is geen koerier: andere aanhef, en de afsluiting gaat niet
  // over verhinderd zijn maar over de vraag die er ligt.
  if (audience === 'pharmacy') {
    return {
      subject: subjectFor(rows),
      text: `Beste ${name},\n\nStand op ${todayNL()}:\n\n${body}\n\n`
          + `Vragen? Bel of mail de planning.\n`,
    };
  }

  return {
    subject: subjectFor(rows),
    text: `Hoi ${name},\n\nStand op ${todayNL()}:\n\n${body}\n\n`
        + `Vragen of verhinderd? Bel de planning.\n`,
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
  // Bij elke run vastleggen in welke stand hij draait; anders is achteraf niet te
  // zien waarom er niets is verstuurd, of juist alles.
  if (ALLOWLIST.length > 0 && LIVE) {
    console.warn(`[mail] MAIL_LIVE staat aan MAAR er is een allowlist van ${ALLOWLIST.length} adres(sen) — de allowlist wint. Wis hem om echt live te gaan.`);
  } else if (ALLOWLIST.length > 0) {
    console.log(`[mail] Testmodus: alleen naar ${ALLOWLIST.length} adres(sen) op de allowlist.`);
  } else if (LIVE) {
    console.warn('[mail] LIVE: er wordt naar alle koeriers verstuurd.');
  } else {
    console.warn('[mail] Geen MAIL_ALLOWLIST en MAIL_LIVE staat niet aan — er wordt NIETS verstuurd. Berichten blijven wachten.');
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  // Leeftijdscontrole vóór alles: naberichten over diensten van te lang geleden
  // gaan op 'expired'. Zonder deze stap stuurt een wachtrij die een tijd heeft
  // stilgestaan — een verkeerd getypte sleutel, een allowlist die dichtstond —
  // alsnog mail over diensten van weken terug zodra hij weer loopt.
  // Ook in een dry run, want anders telt zo'n bericht ten onrechte mee.
  const { data: expired, error: expErr } = await admin.rpc('declaration_expire_stale');
  if (expErr) {
    // Niet fataal: de rest van de post moet gewoon door.
    console.error('[mail] leeftijdscontrole mislukt:', expErr.message);
  } else if ((expired ?? 0) > 0) {
    console.warn(`[mail] ${expired} nabericht(en) vervallen: de dienst is te lang geleden.`);
  }

  // De termijn voor het nabericht, één keer per run. Mislukt dat, dan gaat de
  // mail gewoon uit zonder die zin — een ontbrekende toelichting is geen reden
  // om post te laten liggen.
  const { data: expectedRaw, error: expHourErr } = await admin.rpc('declaration_expected_hours');
  const expectedHours: number | null = expHourErr ? null : (Number(expectedRaw) || null);
  if (expHourErr) console.error('[mail] termijn ophalen mislukt:', expHourErr.message);

  // Meerwerk waar de apotheek niet binnen de termijn op gereageerd heeft. Dit
  // hoort bij het verzendmoment: de klok loopt vanaf het versturen, dus de
  // verzender is de plek die weet wanneer hij is afgelopen.
  const { data: expiredWork, error: xwErr } = await admin.rpc('extra_work_expire');
  if (xwErr) {
    console.error('[mail] meerwerk verlopen bijwerken mislukt:', xwErr.message);
  } else if ((expiredWork ?? 0) > 0) {
    console.warn(`${expiredWork} meerwerkmelding(en) verlopen zonder reactie.`);
  }

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

    // 2. De poort — óók niet claimen, zodat de post uitgaat zodra de beperking
    //    eraf is. In een dry run gaan we wél door, met de uitkomst erbij: juist
    //    de poort wil je kunnen controleren vóór je hem opent.
    const gate = gateFor(address);
    if (!gate.send && !dryRun) {
      console.log(`[mail] ${c.courier_name} <${address}>: ${gate.reason}, ${c.items} bericht(en) blijven wachten.`);
      skipped++;
      results.push({ courier: c.courier_name, skipped: gate.reason, to: address, items: c.items });
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

    // 3b. Invullinks maken voor de naberichten.
    //     Het token wordt HIER gemaakt en niet bij het inschrijven: in de
    //     database staat alleen de hash, dus een token dat in de outbox-payload
    //     zou staan is een werkende link die daar blijft liggen. Uitgeven maakt
    //     een eerdere link ongeldig — dat kan, want een nabericht gaat één keer
    //     per dienst uit.
    for (const r of rows) {
      if (r.kind !== 'shift_followup') continue;   // meerwerk gaat langs de directe lus
      const decId = r.payload?.declaration_id;
      if (!decId) continue;

      if (!DECLARATION_URL) {
        console.error('[mail] DECLARATION_URL ontbreekt — nabericht blijft wachten.');
        continue;
      }
      if (dryRun) {
        // Uitgeven is een schrijfactie en zou de vorige link ongeldig maken.
        r.link = `${DECLARATION_URL}?t=<token wordt pas bij echt verzenden gemaakt>`;
        continue;
      }

      const { data: tok, error: tokErr } = await admin.rpc('declaration_issue_token', {
        p_declaration_id: decId,
      });
      const issued = Array.isArray(tok) ? tok[0] : tok;
      if (tokErr || !issued?.token) {
        // Al afgehandeld of verlopen. Zonder link gaat dit bericht bij 3c terug
        // in de wachtrij in plaats van mee te liften op de uitkomst van de bundel.
        console.error(`[mail] geen invullink voor declaratie ${decId}:`, tokErr?.message ?? 'geen token');
        continue;
      }
      r.link = `${DECLARATION_URL}?t=${issued.token}`;
    }

    // 3c. Naberichten zonder link teruggeven aan de wachtrij.
    //     De bundel krijgt straks ÉÉN uitkomst voor al zijn rijen. Zou zo'n rij
    //     blijven zitten, dan wordt hij als 'sent' afgevinkt terwijl zijn tekst
    //     nooit is uitgegaan — een verdwenen bericht dat je nergens meer ziet.
    //     Terugzetten op 'pending' is de veilige kant: dan gaat hij mee zodra de
    //     link wél gemaakt kan worden, en anders vangt de leeftijdscontrole hem af.
    const linkless = rows.filter((r) => r.kind === 'shift_followup' && !r.link).map((r) => r.id);
    if (linkless.length > 0) {
      if (!dryRun) {
        const { error: relErr } = await admin.rpc('declaration_release', { p_ids: linkless });
        if (relErr) console.error('[mail] terugzetten mislukt:', relErr.message);
      }
      rows = rows.filter((r) => !(r.kind === 'shift_followup' && !r.link));
      console.warn(`[mail] ${c.courier_name}: ${linkless.length} nabericht(en) zonder invullink blijven wachten.`);
      if (rows.length === 0) { skipped++; continue; }
    }

    // 4. Tekst opbouwen.
    const courierName = rows[0].payload?.courier_name ?? c.courier_name;
    const mail = renderMail(rows, courierName, expectedHours);

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
        would_send: gate.send, blocked_by: gate.reason,
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

  // ══ Tweede ronde: post die niet naar een koerier gaat ═══════════════════
  //    Meerwerkmeldingen gaan naar een apotheek (fase 9). Die hebben geen
  //    courier_id en dus geen adres in auth.users; het adres staat in de
  //    outbox-rij zelf. Zelfde volgorde als hierboven: eerst de poort, dan pas
  //    claimen, zodat een geblokkeerd bericht blijft wachten in plaats van als
  //    mislukt te eindigen.
  const { data: direct, error: dirErr } = await admin.rpc('mail_pending_direct');
  if (dirErr) console.error('[mail] mail_pending_direct mislukt:', dirErr.message);

  for (const d of ((direct ?? []) as Array<{ recipient: string; items: number }>)) {
    const gate = gateFor(d.recipient);
    if (!gate.send && !dryRun) {
      console.log(`[mail] ${d.recipient}: ${gate.reason}, ${d.items} bericht(en) blijven wachten.`);
      skipped++;
      results.push({ to: d.recipient, skipped: gate.reason, items: d.items });
      continue;
    }

    let rows: OutboxRow[];
    if (dryRun) {
      const { data } = await admin.from('mail_outbox').select('*')
        .eq('recipient_override', d.recipient).is('courier_id', null).eq('status', 'pending');
      rows = (data ?? []) as OutboxRow[];
    } else {
      const { data, error: claimErr } = await admin.rpc('mail_claim_direct', { p_recipient: d.recipient });
      if (claimErr) {
        console.error(`[mail] claim mislukt voor ${d.recipient}:`, claimErr.message);
        failed++;
        continue;
      }
      rows = (data ?? []) as OutboxRow[];
    }
    if (rows.length === 0) { skipped++; continue; }

    // De link naar de meerwerkpagina. Het token wordt hier gemaakt, net als bij
    // de nadeclaratie: in de database staat alleen de hash.
    const stuck: string[] = [];
    for (const r of rows) {
      if (r.kind !== 'extra_work_request') continue;
      const xwId = r.payload?.extra_work_id;
      if (!xwId || !EXTRA_WORK_URL) {
        if (!EXTRA_WORK_URL) console.error('[mail] EXTRA_WORK_URL ontbreekt — melding blijft wachten.');
        stuck.push(r.id);
        continue;
      }
      if (dryRun) {
        r.link = `${EXTRA_WORK_URL}?t=<token wordt pas bij echt verzenden gemaakt>`;
        continue;
      }
      const { data: tok, error: tokErr } = await admin.rpc('extra_work_issue_token', {
        p_id: xwId,
      });
      const issued = Array.isArray(tok) ? tok[0] : tok;
      if (tokErr || !issued?.token) {
        console.error(`[mail] geen link voor meerwerk ${xwId}:`, tokErr?.message ?? 'geen token');
        stuck.push(r.id);
        continue;
      }
      r.link = `${EXTRA_WORK_URL}?t=${issued.token}`;
    }

    // Zonder link terug in de wachtrij, om dezelfde reden als bij de koeriers:
    // de bundel krijgt één uitkomst, en een rij zonder inhoud zou als verstuurd
    // eindigen terwijl er niets is uitgegaan.
    if (stuck.length > 0) {
      if (!dryRun) {
        // mail_release en niet declaration_release: die laatste filtert op
        // kind = 'shift_followup' en zou een meerwerkmelding op 'sending' laten
        // staan.
        const { error: relErr } = await admin.rpc('mail_release', { p_ids: stuck });
        if (relErr) console.error('[mail] terugzetten mislukt:', relErr.message);
      }
      rows = rows.filter((r) => !stuck.includes(r.id));
      if (rows.length === 0) { skipped++; continue; }
    }

    const toName = rows[0].payload?.pharmacy_name ?? d.recipient;
    const mail = renderMail(rows, toName, expectedHours, 'pharmacy');
    if (!mail) {
      empty++;
      if (!dryRun) {
        await admin.rpc('mail_record_result', {
          p_ids: rows.map((r) => r.id), p_ok: false, p_recipient: d.recipient,
          p_error: 'geen inhoud om te versturen',
        });
      }
      continue;
    }

    if (dryRun) {
      results.push({
        to: d.recipient, would_send: gate.send, blocked_by: gate.reason,
        items: rows.length, kinds: rows.map((r) => r.kind),
        subject: mail.subject, text: mail.text,
      });
      continue;
    }

    let outcome: { ok: boolean; id?: string; error?: string };
    try {
      outcome = await sendMail(d.recipient, toName, mail.subject, mail.text);
    } catch (e) {
      outcome = { ok: false, error: `Netwerkfout: ${e instanceof Error ? e.message : String(e)}` };
    }

    await admin.rpc('mail_record_result', {
      p_ids: rows.map((r) => r.id),
      p_ok: outcome.ok,
      p_recipient: d.recipient,
      p_message_id: outcome.id ?? null,
      p_error: outcome.error ?? null,
    });

    if (outcome.ok) sent++; else failed++;
    results.push({ to: d.recipient, items: rows.length, ok: outcome.ok, error: outcome.error });
  }

  const summary = {
    dry_run: dryRun,
    mode: ALLOWLIST.length > 0 ? `allowlist (${ALLOWLIST.length})` : (LIVE ? 'live' : 'dicht — niets gaat uit'),
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
