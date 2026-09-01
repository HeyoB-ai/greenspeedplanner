import { supabase } from '../lib/supabase';
import { DeclarationRow } from '../types';

// ── Declaraties voor de planner ───────────────────────────────────────────
// Alles loopt via declaration_overview() en declaration_review() (migratie 019).
// shift_declarations heeft geen enkele RLS-policy, dus rechtstreeks lezen kan
// niet — ook niet als planner. Dat is bewust: de tabel bevat token-hashes.
//
// Het overzicht levert bedragen, drempels en tarieven al uitgerekend aan. Er
// staat hier dus geen tarief in de frontend, en een tariefwijziging in de
// database werkt vanzelf door.

function requireClient() {
  if (!supabase) throw new Error('Supabase is niet geconfigureerd.');
  return supabase;
}

export async function getDeclarations(
  fromISO: string | null, toISO: string | null,
): Promise<DeclarationRow[]> {
  const sb = requireClient();
  const { data, error } = await sb.rpc('declaration_overview', {
    p_from: fromISO, p_to: toISO,
  });
  if (error) throw error;
  return (data ?? []) as DeclarationRow[];
}

export type ReviewAction = 'approve' | 'dispute' | 'reopen';

export async function reviewDeclaration(
  declarationId: string, action: ReviewAction, note: string | null,
): Promise<void> {
  const sb = requireClient();
  const { error } = await sb.rpc('declaration_review', {
    p_declaration_id: declarationId, p_action: action, p_note: note,
  });
  if (error) throw error;
}

// Opnieuw doorrekenen na een gecorrigeerde afstand, een nieuwe standplaats of
// een nieuw tarief. Goedgekeurde declaraties blijven ongemoeid: die zijn
// uitbetaald op het tarief dat er toen aan hing.
export async function recomputeOpenDeclarations(): Promise<number> {
  const sb = requireClient();
  const { data, error } = await sb.rpc('declaration_recompute_open');
  if (error) throw error;
  return (data as number) ?? 0;
}

// ── Weergavehulpjes ───────────────────────────────────────────────────────

export const RULE_LABELS: Record<string, string> = {
  own_car:         'eigen auto',
  other_pharmacy:  'andere apotheek',
  above_threshold: 'boven drempel',
  none:            'binnen drempel',
  // Migratie 035: geen recht op vergoeding, dus ook geen bedrag. Kilometers
  // van een zzp'er lopen via de onkosten.
  zzp:             'zzp — geen vergoeding',
};

// -- Dezelfde rit twee keer doorbelast? -----------------------------------
// Een onkostenpost die over kilometers gaat, naast een berekende
// kilometervergoeding op dezelfde declaratie. Dat is wat er bij zzp'ers
// misging voordat migratie 035 er was, en het kan bij loondienst nog steeds
// gebeuren als iemand zijn kilometers voor de zekerheid ook maar even als
// onkost opvoert.
//
// De vergoeding telt alleen mee als de koerier hem ook geclaimd heeft: zonder
// claim komt er niets op de factuur en valt er dus niets dubbel te belasten.
const KM_IN_TEXT = /km|kilometer/i;

export function doubleChargedKm(r: DeclarationRow): string[] {
  if (r.claims_travel !== true) return [];
  if ((r.computed_reimbursable_km ?? 0) <= 0) return [];
  return (r.expenses ?? [])
    .filter((e) => KM_IN_TEXT.test(e.description))
    .map((e) => e.description);
}

export const STATUS_LABELS: Record<string, string> = {
  open:      'niet ingevuld',
  submitted: 'ingediend',
  approved:  'goedgekeurd',
  disputed:  'betwist',
};

// Minuten als '4u 35' — korter dan '4 uur en 35 minuten' en het staat in een
// tabelcel naast een tweede getal waarmee het vergeleken moet worden.
export function minutesText(minutes: number | null): string {
  if (minutes == null) return '—';
  const sign = minutes < 0 ? '−' : '';
  const abs = Math.abs(minutes);
  const h = Math.floor(abs / 60);
  const m = abs % 60;
  if (h === 0) return `${sign}${m}m`;
  return m === 0 ? `${sign}${h}u` : `${sign}${h}u ${m}m`;
}

// Number() eromheen: numerieke kolommen kunnen als string terugkomen zodra een
// waarde niet in een JS-getal past, en dan bestaat toFixed niet.
export function euroText(amount: number | null): string {
  if (amount == null) return '—';
  return `€ ${Number(amount).toFixed(2).replace('.', ',')}`;
}

// Uren als '5,5 u' of '70 u'. Onder de tien uur zegt het halve uur nog iets,
// daarboven leest een heel getal rustiger en is de precisie schijn.
export function hoursText(hours: number | null): string {
  if (hours == null) return '—';
  const h = Number(hours);
  return h < 10 ? `${h.toFixed(1).replace('.', ',')} u` : `${Math.round(h)} u`;
}

export function kmText(km: number | null): string {
  if (km == null) return '—';
  return `${Number(km).toFixed(1).replace('.', ',')} km`;
}
