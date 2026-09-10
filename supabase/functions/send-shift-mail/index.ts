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
const MAIL_FROM_NAME   = Deno.env.get('MAIL_FROM_NAME') ?? 'GoBob Planning';
const MAIL_REPLY_TO    = Deno.env.get('MAIL_REPLY_TO') ?? '';
// Het nummer van de planning, voor de afsluiting van de mail. Leeg is een geldige
// stand: dan blijft de zin zoals hij was, zonder een gat waar een nummer hoort.
const PLANNING_PHONE   = Deno.env.get('PLANNING_PHONE') ?? '';
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
    // alleen bij een herinnering (declaration_reminder)
    stage?: number;              // 1 = eerste, 2 = laatste
    expires_at?: string;         // ISO; de mail noemt hier een DATUM van
    invited_on?: string;         // 'YYYY-MM-DD' — de dag van de uitnodiging
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
  // Geen kolommen maar werkvelden: de invullink wordt vlak vóór het renderen
  // gemaakt en bestaat alleen tijdens deze run. Zie de hoofdlus.
  link?: string;
  // De vervaldatum van diezelfde link, zodat de tekst een DATUM kan noemen in
  // plaats van een aantal dagen. Komt gratis mee uit declaration_issue_token().
  expiresAt?: string;
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

// De vervaldatum als 'dinsdag 4 augustus'. ALTIJD een datum en nooit een aantal
// dagen: token_expires_at staat op dienstdatum + token_valid_days om middernacht,
// dus "over twee dagen" klopt afhankelijk van de starttijd soms wel en soms niet
// — en te ruim is de verkeerde kant op. Omrekenen naar Nederlandse tijd is nodig
// omdat de functie in UTC draait; zonder dat valt de datum een dag terug.
function fmtDeadline(expiresISO: string): string {
  const parts = new Intl.DateTimeFormat('nl-NL', {
    timeZone: 'Europe/Amsterdam', weekday: 'long', day: 'numeric', month: 'long',
  }).formatToParts(new Date(expiresISO));
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? '';
  return `${get('weekday')} ${get('day')} ${get('month')}`;
}

function fmtTime(start: string, end: string | null | undefined): string {
  return end ? `${start}-${end}` : start;
}

function transportText(mode: string | undefined): string {
  return mode === 'car' ? 'met de auto' : 'met de fiets';
}

// De voornaam uit een volledige naam: het eerste woord, dezelfde aanpak als
// DeclarationPage.tsx. Een mail die met "Hoi Hendrick Holthuis" begint leest als
// een brief van een instantie, en dit is een berichtje van de planning. Bij een
// naam met een tussenvoegsel vooraan levert dit soms iets korts op; dat is
// geaccepteerd, want de invulpagina doet het al net zo, en twee plekken die een
// naam verschillend afkappen is erger dan één die het soms simpel doet.
// Splitsen op een spatie en niet op een witruimte-regex, exact zoals daar.
function firstName(full: string): string {
  return full.trim().split(' ')[0] || full;
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

// ── Vorm van een regel ───────────────────────────────────────────────────
// Tekst, of de invullink. Dat onderscheid bestaat alleen omdat de twee
// uitvoeringen hem anders tonen: de tekstversie zet de kale URL neer — die moet
// in élke client klikbaar zijn en is de fallback — en de HTML-versie maakt er een
// knop van, zonder de URL er nóg eens onder te zetten. De blokken worden één keer
// opgebouwd, dus de twee vormen kunnen niet uit elkaar lopen.
type Line = string | { link: string; label: string };

// Eén blok per feit uit de outbox. Zonder aanhef en zonder afsluiting: die zet
// de bundelaar er één keer om heen.
// expectedHours komt uit declaration_settings (migratie 021) en niet uit een getal
// hier: het is een instelling, en twee plekken die 48 zeggen lopen vroeg of laat
// uiteen. Is hij onbekend, dan blijft die zin weg — nooit een termijn beweren die
// niet gelezen is. De vervaldatum komt niet uit een instelling maar uit de
// declaratie zelf (row.expiresAt): een berekening op token_valid_days zou voor een
// oudere declaratie het verkeerde antwoord geven.
function renderBlock(row: OutboxRow, expectedHours: number | null): Line[] {
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
      const lines: Line[] = [
        `Je dienst van ${what} zit erop. Wil je doorgeven hoe lang hij werkelijk duurde?`,
        { link: row.link, label: 'Doorgeven hoe lang mijn dienst duurde' },
      ];
      if (p.own_car) {
        // De vraagstelling staat hier en op de pagina in exact dezelfde woorden.
        // Zonder die definitie telt de een de bezorgroute mee en de ander niet,
        // en zijn de opgaves achteraf niet met elkaar te vergelijken.
        lines.push('Reed je op eigen kosten? Geef dan ook de totaal gereden kilometers op,'
                 + ' vanaf vertrek thuis tot terugkomst thuis.');
      }
      if (expectedHours) {
        // Nadrukkelijk een verwachting en geen deadline, en de tweede helft is
        // geen beleefdheid: een koerier die denkt dat hij te laat is vult
        // helemaal niets meer in, en dan zijn we de opgave kwijt in plaats van
        // dat hij laat is.
        //
        // EEN DATUM, GEEN AANTAL DAGEN. "tot 5 dagen na je dienst" laat de lezer
        // zelf tellen, en die telt vanaf vandaag terwijl de termijn vanaf de
        // DIENSTDATUM loopt — leest hij de mail twee dagen later, dan gokt hij er
        // twee dagen bij. De datum komt uit token_expires_at van deze ene
        // declaratie, dus hij kan niet naast de werkelijkheid liggen. Ontbreekt
        // hij, dan blijft het vaag in plaats van dat er een datum staat die we
        // niet gecontroleerd hebben.
        lines.push(`Fijn als je dit binnen ${expectedHours} uur doorgeeft. `
                 + (row.expiresAt
                     ? `Later kan ook. De link werkt tot ${fmtDeadline(row.expiresAt)}.`
                     : 'Later kan ook. De link blijft nog een tijdje werken.'));
      }
      return lines;
    }
    case 'declaration_reminder': {
      // Zonder vervaldatum kan de kernzin niet gemaakt worden, en een herinnering
      // zonder deadline is precies de herinnering die niets doet. Liever geen
      // bericht dan een half bericht: de rij eindigt dan zichtbaar als mislukt.
      // In de praktijk zet declaration_reminder_claim() dit veld altijd.
      if (!p.shift_date || !p.start_time || !p.expires_at) return [];
      const what = `${dayName(p.weekday ?? 1)} ${fmtDate(p.shift_date)}, ${fmtTime(p.start_time, p.budgeted_end_time)}`
                 + ` bij ${joinNames(p.pharmacies)}`;
      const voor = fmtDeadline(p.expires_at);

      const lines: Line[] = [
        `Je declaratie van ${what} staat nog open: je hebt nog niet doorgegeven hoe lang hij werkelijk duurde.`,
      ];

      // GEEN LINK EN GEEN KNOP. declaration_issue_token() overschrijft
      // token_hash, dus een verse link zou de link in de oorspronkelijke
      // uitnodiging doden — en dan leren we koeriers dat de links van dit systeem
      // stukgaan, precies bij de groep die we wilden bereiken. Het oude token is
      // niet terug te halen (er staat alleen een SHA-256-hash in de database),
      // dus verwijzen naar dezelfde link kan niet. Vandaar de verwijzing naar de
      // mail die de koerier al heeft.
      lines.push(p.invited_on
        ? `De invullink staat in de mail die je op ${fmtDate(p.invited_on)} van ons kreeg.`
        : 'De invullink staat in onze eerdere mail over deze dienst.');

      // Bij de laatste herinnering mag de vervaldatum nadrukkelijker. Nog steeds
      // geen aanmaning: wie zich betrapt voelt vult niets meer in, en dan zijn we
      // de opgave kwijt in plaats van dat hij laat is.
      if (p.stage === 2) {
        lines.push(`Dit is de laatste herinnering. Vul hem in voor ${voor} — daarna werkt de link`
                 + ' niet meer en kunnen we de uren niet meer verwerken.');
      } else {
        lines.push(`Vul hem in voor ${voor}.`);
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
      const lines: Line[] = [
        `De dienst van ${when}${planned} duurde ${minutes} minuten langer dan gepland.`,
      ];
      if (p.note) lines.push(`Toelichting: ${p.note}`);
      lines.push('Ga je akkoord met het doorbelasten van die extra tijd?');
      if (p.own_invoice) {
        // Zonder deze zin denkt de lezer aan de factuur die hij van zijn keten
        // kent, en dat is precies de factuur waar dit NIET op komt.
        lines.push('Deze tijd komt op de factuur van dit filiaal, niet op die van de keten.');
      }
      lines.push({ link: row.link, label: 'Reageren op de extra tijd' });
      lines.push(`Zonder reactie binnen ${p.respond_hours ?? 48} uur belasten we de extra tijd door.`);
      return lines;
    }
    default:
      return [];
  }
}

// Welke soorten om een HANDELING van de lezer vragen. De rest meldt alleen iets.
// Dat onderscheid bepaalt het onderwerp van een gemengde bundel: een koerier die
// "Je planning is bijgewerkt" leest, ziet niet dat er ook iets van hem gevraagd
// wordt, en juist die vraag is de reden dat de mail bestaat.
const ASKS_SOMETHING = new Set(['shift_followup', 'declaration_reminder', 'extra_work_request']);

// Welke soorten over één AFGELOPEN dienst gaan. Bepaalt of de peildatum bovenaan
// de mail nodig is — zie de toelichting bij renderMail(). Een meerwerkmelding
// hoort hier niet bij: die gaat naar een apotheek en vraagt om een beslissing over
// tijd die nog doorbelast moet worden, niet om een terugblik.
const AFGELOPEN_DIENST = new Set(['shift_followup', 'declaration_reminder']);

function subjectFor(rows: OutboxRow[]): string {
  if (rows.length > 1) {
    // Zit er een vraag tussen mededelingen, dan is die vraag het onderwerp.
    // Opnieuw door dezelfde functie, met alléén de vragende rijen: dan komt de
    // datumopmaak van hieronder er gratis bij, en is er geen tweede plek waar een
    // onderwerp wordt samengesteld. Dit kan niet blijven doorlopen — binnen die
    // selectie vraagt élke rij om een handeling, dus de voorwaarde is dan onwaar.
    const asks = rows.filter((r) => ASKS_SOMETHING.has(r.kind));
    if (asks.length > 0 && asks.length < rows.length) return subjectFor(asks);

    // Een bundel die alléén uit naberichten bestaat gaat niet over de planning.
    if (rows.every((r) => r.kind === 'shift_followup')) return 'Hoe lang duurden je diensten?';
    if (rows.every((r) => r.kind === 'extra_work_request')) return 'Extra tijd — graag je akkoord';
    // Een bundel herinneringen gaat over meerdere diensten die allemaal nog open
    // staan; de datums staan in de tekst, niet in het onderwerp.
    if (rows.every((r) => r.kind === 'declaration_reminder')) {
      return rows.some((r) => r.payload?.stage === 2)
        ? 'Laatste herinnering: je declaraties staan nog open'
        : 'Je declaraties staan nog open';
    }
    // Een nabericht én een herinnering in dezelfde bundel: twee soorten, maar voor
    // de lezer één vraag. Zonder deze regel zou de selectie hierboven uitkomen op
    // "Je planning is bijgewerkt" — een onderwerp over planning terwijl er geen
    // planningsbericht meer in de bundel zit.
    if (rows.every((r) => r.kind === 'shift_followup' || r.kind === 'declaration_reminder')) {
      return 'Je declaraties staan nog open';
    }
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
    case 'declaration_reminder':
      if (p.stage === 2) {
        return when ? `Laatste herinnering: je declaratie van ${when}` : 'Laatste herinnering: je declaratie staat nog open';
      }
      return when ? `Je declaratie van ${when} staat nog open` : 'Je declaratie staat nog open';
    case 'extra_work_request':
      return when ? `Extra tijd op ${when} — graag je akkoord` : 'Extra tijd — graag je akkoord';
    default:                   return 'Bericht over je planning';
  }
}

// ── HTML ─────────────────────────────────────────────────────────────────
// Defensief voor Outlook, dat voor mail de Word-renderer gebruikt. Wat die niet
// kent laat hij zonder foutmelding vallen, dus alles wat de mail leesbaar houdt
// moet in iets staan dat hij wél begrijpt:
//   * de opmaak volledig in tabellen — geen flex, geen grid, geen inline-block;
//   * inline styles, want een <style>-blok wordt gestript;
//   * een vaste breedte van 600px en geen media queries;
//   * kleuren die iets dragen ook als attribuut, niet alleen als CSS.
//
// De HTML is de nette vorm, niet de enige: de tekstversie blijft volwaardig en is
// de plek waar de kale URL staat.

const FONT = 'font-family:Arial,Helvetica,sans-serif;';
const BODY_TEXT = `${FONT}font-size:15px;line-height:22px;color:#334155;`;
const PARA = `margin:0 0 16px 0;${BODY_TEXT}`;

// Alles uit de payload gaat hierdoor: apotheeknamen en toelichtingen zijn vrije
// tekst en mogen de opmaak niet kunnen openbreken.
function esc(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// De tekstversie van één regel. De link wordt hier de kale URL: die moet in élke
// client werken, ook waar niets van HTML overblijft.
function lineText(l: Line): string {
  return typeof l === 'string' ? l : l.link;
}

// tel: wil een nummer zonder opmaak; de '+' van de landcode mag blijven staan.
function telHref(phone: string): string {
  return phone.replace(/[^\d+]/g, '');
}

// De afsluiting, in twee vormen. Staat PLANNING_PHONE gezet, dan gaat het nummer
// mee: in de tekst als tekst — daar valt niets te klikken en dat hoeft ook niet —
// en in de HTML als tel:-link, zodat een koerier die op straat staat hem indrukt
// in plaats van hem over te typen. Is de variabele leeg, dan blijft de zin exact
// zoals hij was; een afsluiting met een gat erin is erger dan geen nummer.
//
// De HTML-vorm komt hier al ontsnapt uit en gaat daarom NIET nog een keer door
// esc(): dat zou de anchor tot letterlijke tekst maken.
function closingFor(audience: 'courier' | 'pharmacy'): { text: string; html: string } {
  if (audience === 'pharmacy') {
    const s = 'Vragen? Bel of mail de planning.';
    return { text: s, html: esc(s) };
  }
  if (!PLANNING_PHONE) {
    const s = 'Vragen of verhinderd? Bel de planning.';
    return { text: s, html: esc(s) };
  }
  return {
    text: `Vragen of verhinderd? Bel de planning: ${PLANNING_PHONE}`,
    html: 'Vragen of verhinderd? Bel de planning: '
        + `<a href="tel:${esc(telHref(PLANNING_PHONE))}" style="color:#006b5a;text-decoration:underline;">${esc(PLANNING_PHONE)}</a>`,
  };
}

// withFallback zet de kale URL eronder. Alleen bij de koeriersmail: een knop kan
// sneuvelen — een client die achtergronden strijkt, een tekstweergave, een mail
// die is doorgestuurd — en dan blijft er zonder deze regels niets over om op te
// klikken. De tekstversie heeft de URL altijd al; dit is de HTML-kant van dezelfde
// vangnetgedachte.
//
// word-break:break-all is geen opsmuk: een token van 64 tekens breekt anders de
// kolom van 600px open en laat de hele mail schuiven.
function buttonHtml(l: { link: string; label: string }, withFallback: boolean): string {
  const GREY = `${FONT}font-size:12px;line-height:18px;color:#64748b;`;
  const table = [
    `<table role="presentation" border="0" cellpadding="0" cellspacing="0" style="border-collapse:collapse;margin:0 0 ${withFallback ? '10' : '16'}px 0;">`,
    '  <tr>',
    `    <td bgcolor="#006b5a" align="center" style="background-color:#006b5a;border-radius:4px;padding:13px 22px;${FONT}font-size:15px;font-weight:bold;color:#ffffff;">`,
    `      <a href="${esc(l.link)}" style="${FONT}font-size:15px;font-weight:bold;color:#ffffff;text-decoration:none;">${esc(l.label)}</a>`,
    '    </td>',
    '  </tr>',
    '</table>',
  ].join('\n');

  if (!withFallback) return table;

  return [
    table,
    `<p style="margin:0 0 2px 0;${GREY}">Werkt de knop niet? Gebruik deze link:</p>`,
    `<p style="margin:0 0 16px 0;${GREY}word-break:break-all;">`
      + `<a href="${esc(l.link)}" style="${GREY}word-break:break-all;">${esc(l.link)}</a></p>`,
  ].join('\n');
}

// Eén blok als HTML. Regels binnen een blok horen bij elkaar en worden met
// <br /> gescheiden; een volgend blok begint een nieuwe alinea — dezelfde
// indeling als de tekstversie, die blokken met een lege regel scheidt.
//
// Een opsommingsregel houdt zijn streepje als bullet in plaats van een <ul> te
// worden: op lijsten zet de Word-renderer eigen marges die met inline CSS niet te
// overrulen zijn, en dan staat de halve mail scheef.
function blockHtml(block: Line[], withFallback: boolean): string {
  const out: string[] = [];
  let para: string[] = [];

  const flush = () => {
    if (para.length === 0) return;
    out.push(`<p style="${PARA}">${para.join('<br />')}</p>`);
    para = [];
  };

  for (const l of block) {
    if (typeof l === 'string') {
      para.push(l.startsWith('- ') ? `&#8226;&nbsp;${esc(l.slice(2))}` : esc(l));
    } else {
      // De knop staat op eigen hoogte, dus de alinea ervoor gaat eerst dicht.
      flush();
      out.push(buttonHtml(l, withFallback));
    }
  }
  flush();
  return out.join('\n');
}

// Het omhulsel. Twee tabellen: de buitenste vult de breedte en centreert, de
// binnenste is de kolom van 600px. Een margin:0 auto op die kolom doet in Outlook
// niets, vandaar align="center" op de cel eromheen.
//
// closingHtml komt al ontsnapt binnen (zie closingFor) omdat er een tel:-link in
// kan zitten; alle andere tekst gaat hier wél nog door esc().
function renderHtml(
  blocks: Line[][], greeting: string, stand: string | null, closingHtml: string,
  subject: string, withFallback: boolean,
): string {
  const head = [`<p style="${PARA}">${esc(greeting)}</p>`];
  if (stand) head.push(`<p style="${PARA}">${esc(stand)}</p>`);

  return [
    '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">',
    '<html xmlns="http://www.w3.org/1999/xhtml">',
    '<head>',
    '<meta http-equiv="Content-Type" content="text/html; charset=utf-8" />',
    `<title>${esc(subject)}</title>`,
    '</head>',
    '<body style="margin:0;padding:0;background-color:#f1f5f9;">',
    // bgcolor als ATTRIBUUT naast de CSS, om dezelfde reden als bij de knop:
    // alleen de CSS wordt gestript. Zonder dit valt de mail terug op de
    // achtergrond die de client zelf kiest, en dan staat de witte kaart hieronder
    // op wit en verdwijnt de omlijsting.
    '<table role="presentation" bgcolor="#f1f5f9" border="0" cellpadding="0" cellspacing="0" width="100%" style="border-collapse:collapse;background-color:#f1f5f9;">',
    '  <tr>',
    '    <td align="center" style="padding:24px 12px;">',
    '      <table role="presentation" bgcolor="#ffffff" border="0" cellpadding="0" cellspacing="0" width="600" style="width:600px;border-collapse:collapse;background-color:#ffffff;">',
    '        <tr>',
    `          <td style="padding:24px;${BODY_TEXT}">`,
    ...head,
    blocks.map((b) => blockHtml(b, withFallback)).join('\n'),
    `<p style="margin:0;${BODY_TEXT}">${closingHtml}</p>`,
    '          </td>',
    '        </tr>',
    '      </table>',
    '    </td>',
    '  </tr>',
    '</table>',
    '</body>',
    '</html>',
  ].join('\n');
}

// De volledige mail. Feiten in de volgorde waarin ze ontstonden: bij een
// verzetting staat "vervalt" dan boven "je staat nu op", zoals het gebeurd is.
//
// De PEILDATUM bovenaan is geen opsmuk, maar hij is niet voor elke mail nodig:
//   * Bij een planningsblok is alles onder die regel een momentopname, en de
//     regel maakt hem permanent waar. Verandert er later iets zonder dat het een
//     bericht oplevert — wat kan, want de vingerafdruk kent geen datums — dan is
//     zo'n mail onvolledig in plaats van onwaar. Dat is een veel goedkopere fout,
//     en het is de enige manier om ook het rommelige geval te dekken waarin twee
//     tijden door elkaar heen lopen.
//   * Een nabericht en een herinnering gaan over één dienst die al voorbij is.
//     Daar valt niets meer aan te verschuiven, dus daar voegt de regel niets toe
//     en staat hij alleen maar in de weg. Beide soorten vallen daarom in dezelfde
//     categorie: het onderscheid is niet "welk berichtsoort" maar "gaat dit over
//     een afgelopen dienst of over een doorlopend rooster".
// Vandaar: weg zodra de bundel uitsluitend over afgelopen diensten gaat, en anders
// blijft hij staan. Eén planningsblok in de bundel is genoeg om hem te houden.
//
// Tekst en HTML komen uit dezelfde blokken. Twee losse templates zouden na de
// eerste tekstwijziging al uit elkaar lopen, en dan leest de ene helft van de
// koeriers iets anders dan de andere helft.
function renderMail(
  rows: OutboxRow[], name: string, expectedHours: number | null,
  audience: 'courier' | 'pharmacy' = 'courier',
): { subject: string; text: string; html: string } | null {
  // Kind en regels bij elkaar houden: de peildatum hangt af van wat er
  // daadwerkelijk in de mail komt, niet van wat er in de bundel zat. Een rij die
  // geen inhoud oplevert valt hier weg en mag de aanhef dus ook niet bepalen.
  const rendered = rows
    .slice()
    .sort((a, b) => (a.created_at < b.created_at ? -1 : 1))
    .map((r) => ({ kind: r.kind, lines: renderBlock(r, expectedHours) }))
    .filter((x) => x.lines.length > 0);

  if (rendered.length === 0) return null;

  const blocks = rendered.map((x) => x.lines);
  const subject = subjectFor(rows);
  const stand = rendered.every((x) => AFGELOPEN_DIENST.has(x.kind))
    ? null
    : `Stand op ${todayNL()}:`;
  // Een apotheek is geen koerier: andere aanhef, en de afsluiting gaat niet
  // over verhinderd zijn maar over de vraag die er ligt.
  // Bij een apotheek blijft de hele naam staan: dat is geen persoon maar een zaak.
  const greeting = audience === 'pharmacy' ? `Beste ${name},` : `Hoi ${firstName(name)},`;
  const closing = closingFor(audience);

  const body = blocks.map((b) => b.map(lineText).join('\n')).join('\n\n');
  const head = stand ? `${greeting}\n\n${stand}` : greeting;

  return {
    subject,
    text: `${head}\n\n${body}\n\n${closing.text}\n`,
    // De kale URL onder de knop alleen voor koeriers. Een apotheek krijgt de
    // meerwerkvraag, en daar is de knop de hele boodschap.
    html: renderHtml(blocks, greeting, stand, closing.html, subject, audience === 'courier'),
  };
}

// ── Brevo ────────────────────────────────────────────────────────────────
// Tekst én HTML mee, zodat Brevo er een multipart/alternative van maakt. De
// tekstversie is geen restant: hij is wat een client zonder HTML toont, en de
// enige plek waar de invul-URL uitgeschreven staat.
async function sendMail(
  to: string, toName: string, subject: string, text: string, html: string,
): Promise<{ ok: boolean; id?: string; error?: string }> {
  const body: Record<string, unknown> = {
    sender: { name: MAIL_FROM_NAME, email: MAIL_FROM },
    to: [{ email: to, name: toName }],
    subject,
    textContent: text,
    htmlContent: html,
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

  // Dezelfde controle voor de planningsberichten (migratie 038). Apart gehouden en
  // niet samengevoegd met de vorige: die meet in max_age_days, deze in de
  // starttijd van de dienst. Eén functie met twee maatstaven zou achteraf niet
  // laten zien waaróm een rij is afgesloten.
  //
  // shift_cancelled valt er bewust buiten en gaat dus altijd uit, hoe oud ook:
  // dat bericht is het bewijs dát er afgemeld is, en een koerier die niets hoort
  // over een geannuleerde dienst gaat er misschien alsnog heen.
  const { data: staleplan, error: planErr } = await admin.rpc('mail_expire_stale_planning');
  if (planErr) {
    console.error('[mail] leeftijdscontrole planning mislukt:', planErr.message);
  } else if ((staleplan ?? 0) > 0) {
    console.warn(`[mail] ${staleplan} planningsbericht(en) vervallen: de dienst is al begonnen of de afspraak is afgelopen.`);
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
        // De vervaldatum wél echt ophalen: die staat in de declaratie en is geen
        // schrijfactie. Zonder dit zou juist de deadline-zin in een dry run
        // terugvallen op de vage vorm, en dat is precies de zin die je wil kunnen
        // nalezen voordat er iets uitgaat.
        const { data: dec } = await admin.from('shift_declarations')
          .select('token_expires_at').eq('id', decId).maybeSingle();
        r.expiresAt = dec?.token_expires_at ?? undefined;
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
      // declaration_issue_token() geeft expires_at gratis mee (migratie 019,
      // punt 6). Die is gezaghebbend voor déze declaratie — een berekening op
      // token_valid_days zou voor een oudere declaratie iets anders opleveren dan
      // wat er werkelijk in de rij staat.
      r.expiresAt = issued.expires_at ?? undefined;
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
        subject: mail.subject, text: mail.text, html: mail.html,
      });
      continue;
    }

    // 5. Versturen en 6. vastleggen.
    let outcome: { ok: boolean; id?: string; error?: string };
    try {
      outcome = await sendMail(address, courierName, mail.subject, mail.text, mail.html);
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
        subject: mail.subject, text: mail.text, html: mail.html,
      });
      continue;
    }

    let outcome: { ok: boolean; id?: string; error?: string };
    try {
      outcome = await sendMail(d.recipient, toName, mail.subject, mail.text, mail.html);
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
