// ════════════════════════════════════════════════════════════════════════
// Greenspeed Planner — herinnering voor een openstaande nadeclaratie
// ════════════════════════════════════════════════════════════════════════
// Supabase Edge Function (Deno). Draait elk uur via een cron-schedule; zie de
// README.
//
// Werkwijze per declaratie — claim-dan-versturen:
//   1. declaration_reminder_due()    → wie is aan de beurt, en met welke stap
//   2. declaration_reminder_claim()  → logrij wegschrijven ÉN de mail in de
//                                      outbox zetten, in één transactie. Geeft
//                                      false als een andere run hem al had.
//   3. Brevo aanroepen voor de SMS
//   4. declaration_reminder_record() → uitkomst van de SMS terugschrijven
//
// TWEE KANALEN, ÉÉN CLAIM
//   De mail draagt de context, de SMS is de por. De mail wordt níet hier
//   verstuurd: stap 2 zet een 'declaration_reminder'-rij in mail_outbox en
//   send-shift-mail pikt die op bij zijn eigen ronde. Dat betekent dat de
//   herinnering meelift op de allowlist, de bundeling en de HTML-variant die daar
//   al staan, en dat er hier geen tweede plek is waar mail wordt opgemaakt.
//
// GEEN LINK, GEEN NIEUW TOKEN
//   declaration_issue_token() wordt hier niet aangeroepen en mag dat ook niet:
//   die overschrijft token_hash, dus een verse link maakt de link in de
//   oorspronkelijke uitnodiging dood. Dat zou koeriers leren dat de links van dit
//   systeem stukgaan — precies bij de groep die we met een herinnering wilden
//   bereiken. De plaintext van het oude token bestaat nergens meer (er staat
//   alleen een SHA-256-hash in de database), dus verwijzen naar dezelfde link kan
//   niet. Daarom verwijst zowel de SMS als de mail naar de eerdere mail.
//
// Crasht het proces tussen 2 en 3, dan blijft de rij op 'sending' staan en gaat
// er géén SMS meer uit voor die stap. Bewust: een gemiste por die je in de tabel
// ziet is goedkoper dan een dubbele bij de koerier. De mail is dan wél al
// ingeschreven en gaat gewoon uit.
// ════════════════════════════════════════════════════════════════════════

import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const SUPABASE_URL     = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const BREVO_API_KEY    = Deno.env.get('BREVO_API_KEY') ?? '';
const SMS_SENDER       = Deno.env.get('SMS_SENDER') ?? 'Greenspeed';
const CRON_SECRET      = Deno.env.get('CRON_SECRET') ?? '';
// Veiligheidsrem, net als bij de dienstherinnering: bij een verkeerd gezette
// termijn niet ongemerkt honderden berichten sturen. Het overschot komt de
// volgende run aan de beurt.
const MAX_PER_RUN      = Number(Deno.env.get('REMINDER_MAX_PER_RUN') ?? '50');

interface DueReminder {
  declaration_id: string;
  stage: number;                    // 1 = eerste, 2 = laatste
  courier_id: string;
  courier_name: string;
  phone_e164: string | null;        // NULL = geen nummer bekend
  shift_id: string;
  shift_date: string;               // 'YYYY-MM-DD'
  start_time: string;
  budgeted_end_time: string | null;
  pharmacy_names: string[];
  invited_on: string;               // 'YYYY-MM-DD' — de dag van de uitnodiging
  expires_at: string;               // ISO, timestamptz
  due_at: string;
}

// ── Berichttekst ─────────────────────────────────────────────────────────
// Eén segment, en dat is geen toeval: er staat geen URL in. Zou die er wel in
// staan, dan is het bericht 103 tekens langer en blijft er niets over om iets uit
// te leggen — nog los van het tokenprobleem in de kop.
//
// Randvoorwaarden, dezelfde als bij de dienstherinnering:
//   * Géén accenttekens. Eén accent zet het hele bericht om naar Unicode en dan
//     is een segment 70 tekens in plaats van 160. toGsm7() haalt ze eruit.
//   * ALTIJD een datum, nooit een aantal dagen. token_expires_at staat op
//     dienstdatum + token_valid_days om middernacht, dus "over twee dagen" klopt
//     afhankelijk van de starttijd soms wel en soms niet — en te ruim is de
//     verkeerde kant op.
//   * Geen patiëntgegevens, geen apotheeknamen: de dienstdatum is genoeg om te
//     weten welke dienst bedoeld wordt, en korter.
//   * De afzender is alfanumeriek, dus terug-sms'en kan niet. Bij stage 1 staat
//     daarom waar je wél terecht kunt.
function buildMessage(r: DueReminder): string {
  const dienst = `${shortDay(r.shift_date)} ${dayMonth(r.shift_date)}`;
  const mail = dayMonth(r.invited_on);
  const voor = deadline(r.expires_at);

  if (r.stage === 2) {
    return toGsm7(
      `Laatste herinnering: je declaratie van ${dienst} staat nog open. `
      + `Vul hem in via de mail van ${mail}, voor ${voor}. Daarna kan het niet meer`,
    );
  }
  return toGsm7(
    `Je declaratie van ${dienst} staat nog open. `
    + `Vul hem in via de mail van ${mail}, voor ${voor}. Vragen? Bel de planning`,
  );
}

// ── Datums ───────────────────────────────────────────────────────────────
// 'YYYY-MM-DD' → 'do'. Via Date.UTC en getUTCDay: een datumstring aan new Date()
// geven laat sommige omgevingen een dag opschuiven.
const SHORT_DAYS = ['zo', 'ma', 'di', 'wo', 'do', 'vr', 'za'];

function shortDay(iso: string): string {
  const [y, m, d] = iso.split('-').map(Number);
  return SHORT_DAYS[new Date(Date.UTC(y, m - 1, d)).getUTCDay()];
}

// 'YYYY-MM-DD' → '30-07'. Puur op de string, dus geen tijdzone die een datum een
// dag kan verschuiven.
function dayMonth(iso: string): string {
  const [, m, d] = iso.split('-');
  return `${d}-${m}`;
}

// De vervaldatum als 'ma 4 aug'. token_expires_at is een timestamptz op
// middernacht Europe/Amsterdam; de functie draait in UTC, dus hier expliciet
// terugrekenen. Zonder die omzetting valt de datum een dag terug.
function deadline(expiresISO: string): string {
  const parts = new Intl.DateTimeFormat('nl-NL', {
    timeZone: 'Europe/Amsterdam',
    weekday: 'short', day: 'numeric', month: 'short',
  }).formatToParts(new Date(expiresISO));
  const get = (t: string) => (parts.find((p) => p.type === t)?.value ?? '').replace('.', '');
  return `${get('weekday')} ${get('day')} ${get('month')}`;
}

// Accenten en typografische tekens terugbrengen tot GSM-7-veilige ASCII, zodat
// het bericht in één segment past. Letterlijk overgenomen uit
// send-shift-reminders: twee keer dezelfde bewerking hoort twee keer hetzelfde te
// doen, en die functie is de bestaande waarheid.
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

// Lengte en segmenten, voor de dry run. Eén segment is 160 tekens in GSM-7; komt
// er een tweede bij, dan zakt de ruimte naar 153 per segment door de koppelkop.
// Staat er tóch een teken in dat niet in GSM-7 past, dan wordt het hele bericht
// Unicode: 70, daarna 67.
const GSM7 =
  '@£$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !"#¤%&\'()*+,-./0123456789:;<=>?¡'
  + 'ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà';
const GSM7_SET = new Set([...GSM7, ...'{}[]~^|\€']);

function messageInfo(text: string): { chars: number; segments: number; unicode: boolean } {
  const unicode = [...text].some((ch) => !GSM7_SET.has(ch));
  const single = unicode ? 70 : 160;
  const multi  = unicode ? 67 : 153;
  const chars = [...text].length;
  return { chars, segments: chars <= single ? 1 : Math.ceil(chars / multi), unicode };
}

// ── Brevo ────────────────────────────────────────────────────────────────
// Transactionele SMS. 'recipient' wil het nummer zonder '+' (landcode + nummer).
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
      tag: 'declaratieherinnering',
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

  // Proefdraaien: haalt op en stelt de berichten samen, maar claimt niets,
  // verstuurt niets en schrijft geen mail in de outbox. Bedoeld voor de eerste
  // keer — dan zie je precies wie er een bericht zou krijgen voordat het gebeurt.
  const url = new URL(req.url);
  const dryRun = url.searchParams.get('dry_run') === '1'
              || (Deno.env.get('REMINDER_DRY_RUN') ?? '') === '1';

  if (!dryRun && !BREVO_API_KEY) {
    return json({ error: 'BREVO_API_KEY ontbreekt' }, 500);
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const { data, error } = await admin.rpc('declaration_reminder_due', { p_limit: MAX_PER_RUN });
  if (error) {
    console.error('[herinnering] declaration_reminder_due mislukt:', error.message);
    return json({ error: error.message }, 500);
  }

  const due = (data ?? []) as DueReminder[];
  const results: Array<Record<string, unknown>> = [];
  let sent = 0, failed = 0, skipped = 0, noPhone = 0, mailsQueued = 0;

  for (const r of due) {
    const content = buildMessage(r);

    if (dryRun) {
      const info = messageInfo(content);
      results.push({
        declaration: r.declaration_id,
        stage: r.stage,
        courier: r.courier_name,
        to: r.phone_e164 ?? '(geen nummer)',
        shift_date: r.shift_date,
        due_at: r.due_at,
        expires_at: r.expires_at,
        chars: info.chars,
        segments: info.segments,
        encoding: info.unicode ? 'unicode (70/67 per segment)' : 'gsm-7 (160/153 per segment)',
        content,
      });
      continue;
    }

    // Claimen gaat vóór de controle op het nummer, en dat is met opzet: de claim
    // schrijft óók de mail in de outbox, en die moet uitgaan ongeacht of er een
    // SMS bij kan. Zou de volgorde omgekeerd zijn, dan zou een ontbrekend nummer
    // ook de mail tegenhouden — en dan straft een fout in de gegevens de koerier
    // in plaats van de invoer.
    const { data: claimed, error: claimErr } = await admin.rpc('declaration_reminder_claim', {
      p_declaration_id: r.declaration_id, p_stage: r.stage,
    });
    if (claimErr) {
      console.error(`[herinnering] claim mislukt voor declaratie ${r.declaration_id}:`, claimErr.message);
      failed++;
      continue;
    }
    if (claimed !== true) {
      // Andere run was ons voor. Precies wat de sleutel moet doen.
      skipped++;
      continue;
    }
    mailsQueued++;

    // Alle koeriers horen een nummer te hebben — zonder nummer kunnen ze ook niet
    // in de WhatsApp-groepen. Dit is dus een fout in de gegevens en geen
    // situatie om op te vangen: melden met naam en id, zodat hij op te zoeken is,
    // en vastleggen als mislukt zodat hij ook zichtbaar blijft voor wie de logs
    // niet leest. De mail is op dat moment al ingeschreven.
    if (!r.phone_e164) {
      console.warn(
        `[herinnering] ${r.courier_name} (${r.courier_id}): geen telefoonnummer in `
        + `courier_contacts — geen SMS. De mail gaat wel uit. Vul het nummer aan.`,
      );
      noPhone++;
      await admin.rpc('declaration_reminder_record', {
        p_declaration_id: r.declaration_id, p_stage: r.stage, p_ok: false,
        p_message_id: null, p_error: 'geen telefoonnummer bij deze koerier',
      });
      results.push({ declaration: r.declaration_id, stage: r.stage, courier: r.courier_name,
                     ok: false, error: 'geen telefoonnummer', mail_queued: true });
      continue;
    }

    let outcome: { ok: boolean; id?: string; error?: string };
    try {
      outcome = await sendSms(r.phone_e164, content);
    } catch (e) {
      outcome = { ok: false, error: `Netwerkfout: ${e instanceof Error ? e.message : String(e)}` };
    }

    const { error: recErr } = await admin.rpc('declaration_reminder_record', {
      p_declaration_id: r.declaration_id,
      p_stage: r.stage,
      p_ok: outcome.ok,
      p_message_id: outcome.id ?? null,
      p_error: outcome.error ?? null,
    });
    if (recErr) {
      // Het bericht is dan wél de deur uit maar de rij staat nog op 'sending'.
      // Loggen en doorgaan: opnieuw versturen zou een dubbele opleveren.
      console.error(`[herinnering] resultaat wegschrijven mislukt voor ${r.declaration_id}:`, recErr.message);
    }

    if (outcome.ok) {
      sent++;
    } else {
      failed++;
      console.error(`[herinnering] SMS mislukt voor ${r.declaration_id}:`, outcome.error);
    }
    results.push({ declaration: r.declaration_id, stage: r.stage, courier: r.courier_name,
                   ok: outcome.ok, error: outcome.error, mail_queued: true });
  }

  const summary = {
    dry_run: dryRun,
    due: due.length,
    stage1: due.filter((r) => r.stage === 1).length,
    stage2: due.filter((r) => r.stage === 2).length,
    sent,
    failed,
    skipped,
    // Apart geteld: dit is geen storing maar ontbrekende invoer, en het hoort in
    // het weekoverzicht van wie de nummers beheert.
    zonder_nummer: noPhone,
    mails_queued: mailsQueued,
    // Elk segment is een credit; bij tweesegmentsberichten wijkt dit af van het
    // aantal berichten.
    segments_total: dryRun
      ? results.reduce((n, r) => n + (r.segments as number ?? 0), 0)
      : undefined,
    results: dryRun ? results : undefined,
  };
  console.log('[herinnering]', JSON.stringify({ ...summary, results: undefined }));
  return json(summary, 200);
});

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status, headers: { 'Content-Type': 'application/json' },
  });
}
