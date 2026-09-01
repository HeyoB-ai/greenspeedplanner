import { supabase } from '../lib/supabase';
import { Chain, InvoiceLine, PharmacyRate } from '../types';

// ── Facturatie richting apotheken (fase 7, migratie 025) ──────────────────
// Alle bedragen komen uit invoice_lines(); er staat hier geen tarief en geen
// verdeelregel. Een tariefwijziging in de database werkt daardoor vanzelf door,
// en er is één plek waar de rekenregels staan.

function requireClient() {
  if (!supabase) throw new Error('Supabase is niet geconfigureerd.');
  return supabase;
}

export async function getInvoiceLines(
  pharmacyId: string, fromISO: string, toISO: string,
): Promise<InvoiceLine[]> {
  const sb = requireClient();
  const { data, error } = await sb.rpc('invoice_lines', {
    p_pharmacy_id: pharmacyId, p_from: fromISO, p_to: toISO,
  });
  if (error) throw error;
  return (data ?? []) as InvoiceLine[];
}

// De ketens met hun facturatie-instelling (migratie 032).
export async function getChains(): Promise<Chain[]> {
  const sb = requireClient();
  const { data, error } = await sb.rpc('chain_overview');
  if (error) throw error;
  return (data ?? []) as Chain[];
}

export async function setChainBilling(
  groupId: string, email: string | null, split: boolean,
): Promise<void> {
  const sb = requireClient();
  const { error } = await sb.rpc('set_group_billing', {
    p_group_id: groupId, p_email: email, p_split: split,
  });
  if (error) throw error;
}

// De factuur van een keten: de regels van al haar filialen, waarvan alleen het
// ketendeel meetelt. Bewust hier en niet in SQL — zie de toelichting in
// migratie 032 — en het gaat om een handvol apotheken per keten.
export async function getChainInvoiceLines(
  pharmacyIds: string[], fromISO: string, toISO: string,
): Promise<InvoiceLine[]> {
  const perPharmacy = await Promise.all(
    pharmacyIds.map((id) => getInvoiceLines(id, fromISO, toISO)));
  return perPharmacy.flat();
}

export async function getPharmacyRates(pharmacyId: string): Promise<PharmacyRate[]> {
  const sb = requireClient();
  const { data, error } = await sb
    .from('pharmacy_rates')
    .select('id, pharmacy_id, hourly_rate_bike, hourly_rate_car, '
          + 'hourly_rate_institution, hourly_rate_other, start_rate, effective_from, note')
    .eq('pharmacy_id', pharmacyId)
    .order('effective_from', { ascending: false });
  if (error) throw error;
  return (data ?? []).map((r: any): PharmacyRate => ({
    id: r.id,
    pharmacyId: r.pharmacy_id,
    hourlyRateBike: r.hourly_rate_bike != null ? Number(r.hourly_rate_bike) : null,
    hourlyRateCar: r.hourly_rate_car != null ? Number(r.hourly_rate_car) : null,
    hourlyRateInstitution: r.hourly_rate_institution != null ? Number(r.hourly_rate_institution) : null,
    hourlyRateOther: r.hourly_rate_other != null ? Number(r.hourly_rate_other) : null,
    startRate: Number(r.start_rate),
    effectiveFrom: r.effective_from,
    note: r.note ?? null,
  }));
}

// Een tarief vastleggen. Dezelfde ingangsdatum opnieuw invoeren corrigeert die
// rij; een nieuwe datum is een tariefwijziging en laat de oude staan — anders is
// een oude factuur niet meer te herleiden.
export interface RateInput {
  bike: number | null;
  car: number | null;
  institution: number | null;
  other: number | null;
  startRate: number;
}

export async function setPharmacyRate(
  pharmacyId: string, rates: RateInput, effectiveFrom: string, note: string | null,
): Promise<void> {
  const sb = requireClient();
  const { error } = await sb.rpc('set_pharmacy_rate', {
    p_pharmacy_id: pharmacyId,
    p_bike: rates.bike,
    p_car: rates.car,
    p_institution: rates.institution,
    p_other: rates.other,
    p_start_rate: rates.startRate,
    p_effective_from: effectiveFrom,
    p_note: note,
  });
  if (error) throw error;
}

export async function deletePharmacyRate(rateId: string): Promise<void> {
  const sb = requireClient();
  const { error } = await sb.rpc('delete_pharmacy_rate', { p_rate_id: rateId });
  if (error) throw error;
}

// ── Optellen ──────────────────────────────────────────────────────────────
// Bedragen worden hier alleen opgeteld, niet berekend. Een regel zonder tarief
// heeft geen totaal (null) en telt dus nergens in mee; die staat apart geteld,
// zodat een subtotaal nooit stilzwijgend te laag is.
export interface InvoiceTotals {
  hours: number;
  start: number;
  travel: number;
  expenses: number;
  urgent: number;
  total: number;
  billedMinutes: number;
  lines: number;
  incomplete: number;
  withoutTotal: number;
  // Verdeling over de twee facturen (migratie 032). Zonder splitsing is chain 0.
  chain: number;
  branch: number;
}

export function sumLines(lines: InvoiceLine[]): InvoiceTotals {
  const t: InvoiceTotals = {
    hours: 0, start: 0, travel: 0, expenses: 0, urgent: 0, total: 0,
    billedMinutes: 0, lines: lines.length, incomplete: 0, withoutTotal: 0,
    chain: 0, branch: 0,
  };
  for (const l of lines) {
    t.hours  += Number(l.hours_amount ?? 0);
    t.start  += Number(l.start_amount ?? 0);
    t.travel += Number(l.travel_amount ?? 0);
    t.expenses += Number(l.expenses_amount ?? 0);
    t.urgent += Number(l.urgent_amount ?? 0);
    t.billedMinutes += Number(l.billed_minutes ?? 0);
    if (l.line_total == null) t.withoutTotal += 1;
    else t.total += Number(l.line_total);
    t.chain  += Number(l.chain_amount ?? 0);
    t.branch += Number(l.branch_amount ?? 0);
    if (l.incomplete) t.incomplete += 1;
  }
  return t;
}

export function euro(value: number | null): string {
  if (value == null) return '—';
  return `€ ${Number(value).toFixed(2).replace('.', ',')}`;
}

// Alleen het getal, zonder euroteken. In een tabel met vijf bedragkolommen kost
// dat teken per cel breedte die er niet is, en bij te weinig breedte breekt
// "€ 12,34" af — dan staat het teken bóven het bedrag. Het teken staat daarom
// één keer in de kolomkop en één keer op de totaalregel.
export function amount(value: number | null): string {
  if (value == null) return '—';
  return Number(value).toFixed(2).replace('.', ',');
}

// Minuten als '4:35' — in een factuuroverzicht staan uren naast bedragen, en
// dan leest een klokvorm rustiger dan '275 min'.
export function hoursText(minutes: number | null): string {
  if (minutes == null) return '—';
  const total = Math.round(Number(minutes));
  const h = Math.floor(total / 60);
  const m = total % 60;
  return `${h}:${String(m).padStart(2, '0')}`;
}
