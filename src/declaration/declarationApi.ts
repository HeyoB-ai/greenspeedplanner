// ── De invulpagina praat uitsluitend met de Edge Function ─────────────────
// Niet met PostgREST: shift_declarations heeft geen enkele RLS-policy, dus de
// anon-sleutel komt niet bij die tabel — precies de bedoeling. De functie
// draait als service-role en het token bepaalt welke ene rij bereikbaar is.
//
// De anon-sleutel gaat wel mee als Authorization-header: Supabase eist voor elke
// Edge Function een geldige sleutel. Die sleutel geeft op zichzelf nergens
// toegang toe; het token doet het werk.

const URL_BASE = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const ANON = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

export const declarationConfigured = !!URL_BASE && !!ANON;

// Wat de pagina van één declaratie mag weten. Uitsluitend deze dienst, ter
// herkenning — geen gegevens van anderen, en geen berekende bedragen.
export interface DeclarationView {
  declaration_id: string;
  // Sinds migratie 023 komen 'approved' en 'disputed' ook terug: de link werkt
  // dan nog, er valt alleen niets meer in te vullen. De pagina toont die twee
  // als leesweergave.
  status: 'open' | 'submitted' | 'approved' | 'disputed';
  courier_name: string;
  shift_date: string;              // 'YYYY-MM-DD'
  start_time: string;              // 'HH:MM'
  budgeted_end_time: string | null;
  transport_mode: 'bike' | 'car';
  own_car: boolean;                // eigen auto → dan pas vragen we kilometers
  pharmacies: string[];
  actual_start: string | null;
  actual_end: string | null;
  claims_travel: boolean | null;
  own_car_km: number | null;
  courier_note: string | null;
  submitted_at: string | null;
  // Onkosten die geen kilometervergoeding zijn (migratie 028). Het bonnetje zit
  // niet in het systeem: dat gaat per mail naar de planning.
  expenses: { description: string; amount_eur: number }[];
  // Wordt er van deze koerier een bon verwacht? Een herinnering, geen voorwaarde.
  expects_receipt: boolean;
  // Waarom de planning betwist heeft. Bij goedgekeurd meestal leeg; bij betwist
  // is dit het enige wat de koerier verder helpt.
  review_note: string | null;
  // Zzp'er (migratie 035): dan geen reiskostenvraag. Kilometers horen bij deze
  // koerier in het onkostenblok, want een vergoeding waar geen recht op bestaat
  // zou naast die post nog eens worden doorbelast.
  is_contractor: boolean;
  // Staat er een BENU selfbilling-filiaal op deze dienst (migratie 051)? Dan
  // komen de tijden van de PDA van de apotheek en niet van de klok van de
  // koerier. Zonder die aanwijzing vult de helft zijn eigen tijden in en klopt
  // de facturatie niet — BENU factureert zichzelf op hun eigen registratie.
  is_benu_selfbilling: boolean;
  // Vanaf hoeveel minuten uitloop er een toelichting nodig is. Komt uit
  // invoice_settings, dezelfde drempel die extra_work_sweep() aanhoudt, zodat
  // het scherm nooit om iets vraagt dat nergens heen gaat. NULL = niet van
  // toepassing: een spoeddienst of een dienst zonder begrote eindtijd.
  explain_over_minutes: number | null;
  // De tijd volgens de PDA van de apotheek (migratie 053). Alleen bij een BENU
  // selfbilling-dienst; dit is de tijd die BENU vergoedt, en waartegen de
  // uitloop wordt gemeten.
  pda_start: string | null;
  pda_end: string | null;
}

export interface SubmitInput {
  actualStart: string;             // 'HH:MM'
  actualEnd: string;               // 'HH:MM'
  claimsTravel: boolean;
  ownCarKm: number | null;
  note: string | null;
  // De PDA-tijd (migratie 053). Altijd meesturen, ook als hij leeg is: de
  // database beslist of deze dienst er een hoort te hebben, en gooit hem weg bij
  // een niet-BENU-dienst. Zou het scherm hier zelf over beslissen, dan zijn er
  // twee plekken die weten wat een BENU-dienst is.
  pdaStart: string | null;
  pdaEnd: string | null;
  // De hele lijst gaat mee, ook als hij leeg is: de server vervangt wat er stond.
  // Per regel bijhouden wat gewijzigd is levert alleen toestand op die uit de pas
  // kan lopen.
  expenses: { description: string; amount_eur: string }[];
}

// Het token bestaat niet. Eén nietszeggende melding, want de server maakt hier
// bewust geen onderscheid: uit het proberen van tokens valt zo niets te leren.
export class LinkInvalidError extends Error {
  constructor() { super('link_ongeldig'); }
}

// Het token klopt wél, maar er valt niets meer op te slaan: de link is verlopen,
// de planning kijkt ernaar, of de declaratie is al goedgekeurd (migratie 022).
// De server levert de bijpassende zin aan; die staat niet in deze code, zodat er
// maar één plek is waar die tekst vandaan komt.
export class DeclarationClosedError extends Error {
  constructor(message: string) { super(message); }
}

function endpoint(): string {
  return `${URL_BASE}/functions/v1/shift-declaration`;
}

function headers(): Record<string, string> {
  return {
    'Content-Type': 'application/json',
    'apikey': ANON!,
    'Authorization': `Bearer ${ANON}`,
  };
}

async function parse(res: Response): Promise<any> {
  let body: any = null;
  try { body = await res.json(); } catch { /* leeg antwoord */ }
  if (res.ok) return body;
  if (body?.error === 'link_ongeldig') throw new LinkInvalidError();
  if (body?.closed) throw new DeclarationClosedError(body.error);
  throw new Error(body?.error ?? 'Er ging iets mis. Probeer het later opnieuw.');
}

export interface LoadedDeclaration {
  declaration: DeclarationView;
  // Binnen hoeveel uur na de dienst we de opgave graag hebben (migratie 021).
  // Een verwachting, geen grens: de link blijft werken tot hij verloopt. Komt
  // uit declaration_settings, dus dit getal staat nergens in de pagina.
  expectedWithinHours: number | null;
}

export async function loadDeclaration(token: string): Promise<LoadedDeclaration> {
  if (!declarationConfigured) throw new Error('De pagina is niet goed ingesteld.');
  const res = await fetch(`${endpoint()}?t=${encodeURIComponent(token)}`, { headers: headers() });
  const body = await parse(res);
  if (!body?.declaration) throw new LinkInvalidError();
  return {
    declaration: body.declaration as DeclarationView,
    expectedWithinHours: body.expected_within_hours ?? null,
  };
}

export async function submitDeclaration(
  token: string, input: SubmitInput,
): Promise<DeclarationView | null> {
  if (!declarationConfigured) throw new Error('De pagina is niet goed ingesteld.');
  const res = await fetch(endpoint(), {
    method: 'POST',
    headers: headers(),
    body: JSON.stringify({
      token,
      actual_start: input.actualStart,
      actual_end: input.actualEnd,
      claims_travel: input.claimsTravel,
      own_car_km: input.ownCarKm,
      note: input.note,
      pda_start: input.pdaStart,
      pda_end: input.pdaEnd,
      expenses: input.expenses,
    }),
  });
  const body = await parse(res);
  return (body?.declaration ?? null) as DeclarationView | null;
}

// ── Weergavehulpjes ───────────────────────────────────────────────────────
const WEEKDAYS = ['zondag', 'maandag', 'dinsdag', 'woensdag', 'donderdag', 'vrijdag', 'zaterdag'];

// 'YYYY-MM-DD' → 'donderdag 30-07-2026'. De datum wordt als losse getallen aan
// Date gegeven, niet als string: die laatste route schuift in sommige browsers
// een dag op door de tijdzone.
export function formatDate(iso: string): string {
  const [y, m, d] = iso.split('-').map(Number);
  const day = WEEKDAYS[new Date(y, m - 1, d).getDay()];
  return `${day} ${String(d).padStart(2, '0')}-${String(m).padStart(2, '0')}-${y}`;
}

export function joinNames(names: string[]): string {
  if (!names || names.length === 0) return 'de apotheek';
  if (names.length === 1) return names[0];
  return `${names.slice(0, -1).join(', ')} en ${names[names.length - 1]}`;
}

// Is dit een geldige klokstand? Dezelfde vorm als de controle in de Edge
// Function, zodat het scherm niets doorlaat wat daar alsnog sneuvelt.
export function isTime(value: string): boolean {
  return /^([01]\d|2[0-3]):[0-5]\d$/.test(value);
}

// Losse cijfers naar 'HH:MM', terwijl er getypt wordt. De tijdvelden zijn
// tekstvelden en geen <input type="time">, omdat die laatste geen placeholder
// toont en de geplande tijd juist grijs IN het vakje hoort te staan. Prijs
// daarvan is de klok-kiezer op de telefoon; vandaar dat de dubbele punt hier
// zelf gezet wordt. Wie 0952 typt ziet 09:52 verschijnen, en wie hem zelf
// intypt merkt er niets van — non-digits gaan er eerst uit.
export function timeMask(raw: string): string {
  const cijfers = raw.replace(/\D/g, '').slice(0, 4);
  return cijfers.length <= 2 ? cijfers : `${cijfers.slice(0, 2)}:${cijfers.slice(2)}`;
}

// Duur tussen twee 'HH:MM'-tijden in minuten, over middernacht heen. De
// tegenhanger van duration_minutes() in de database (migratie 051), met dezelfde
// behandeling van een eindtijd op of vóór de begintijd. Die twee horen hetzelfde
// te rekenen: het scherm bepaalt hiermee of het om een toelichting vraagt, en de
// database of hij die eist.
export function minutesBetween(start: string, end: string): number | null {
  if (!/^\d{2}:\d{2}$/.test(start) || !/^\d{2}:\d{2}$/.test(end)) return null;
  const [sh, sm] = start.split(':').map(Number);
  const [eh, em] = end.split(':').map(Number);
  const minutes = eh * 60 + em - (sh * 60 + sm);
  return minutes <= 0 ? minutes + 24 * 60 : minutes;
}

// Waartegen de uitloop gemeten is. Het scherm moet dat kunnen zéggen: "langer
// bezig dan gepland" en "langer bezig dan de PDA-tijd" zijn voor een koerier
// twee verschillende verwijten, en alleen één ervan is er een waar hij iets aan
// had kunnen doen.
export interface Overrun {
  minutes: number;            // werkelijke duur min referentie; negatief = eerder klaar
  basis: 'pda' | 'gepland';
}

// Hoeveel langer de dienst duurde dan de referentietijd — de tegenhanger van
// reference_minutes() uit migratie 053, met dezelfde volgorde:
//
//   BENU mét PDA-tijd  → de PDA-tijd, want dat is wat BENU al vergoedt
//   anders             → de begrote tijd
//   geen van beide     → NULL, er valt niets te overschrijden
//
// Die volgorde moet hier gelijk zijn aan die in de database. Meet het scherm
// tegen iets anders dan declaration_submit(), dan wordt er om een toelichting
// gevraagd die de facturatie niet herkent, of gaat er een verzoek naar de
// apotheek waar de koerier nooit naar gevraagd is.
//
// Een half getypte PDA-tijd telt als niet ingevuld en valt dus terug op de
// begroting — precies wat de database met een NULL doet. Zodra het laatste
// cijfer staat verspringt de uitkomst naar de PDA-tijd, en zegt het scherm er
// meteen bij dat het nu daartegen meet.
export function overrunMinutes(o: {
  isBenu: boolean;
  pdaStart: string; pdaEnd: string;
  plannedStart: string; plannedEnd: string | null;
  actualStart: string; actualEnd: string;
}): Overrun | null {
  const echt = minutesBetween(o.actualStart, o.actualEnd);
  if (echt === null) return null;

  if (o.isBenu && isTime(o.pdaStart) && isTime(o.pdaEnd)) {
    const pda = minutesBetween(o.pdaStart, o.pdaEnd);
    if (pda !== null) return { minutes: echt - pda, basis: 'pda' };
  }

  if (!o.plannedEnd) return null;
  const begroot = minutesBetween(o.plannedStart, o.plannedEnd);
  if (begroot === null) return null;
  return { minutes: echt - begroot, basis: 'gepland' };
}

// Hoe het scherm naar die referentie verwijst. Staat hier en niet in de pagina,
// zodat de melding onder de knop en het label boven het tekstvak niet elk hun
// eigen bewoording krijgen.
export function overrunBasisText(basis: Overrun['basis']): string {
  return basis === 'pda' ? 'de PDA-tijd' : 'gepland';
}

// Duur tussen twee 'HH:MM'-tijden, over middernacht heen. Alleen om de koerier
// te laten zien wat hij invult; de database rekent zelf opnieuw.
export function durationText(start: string, end: string): string | null {
  const minutes = minutesBetween(start, end);
  if (minutes === null) return null;
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  if (h === 0) return `${m} minuten`;
  return m === 0 ? `${h} uur` : `${h} uur en ${m} minuten`;
}
