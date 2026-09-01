import { supabase } from '../lib/supabase';
import { ExtraWorkRow } from '../types';

// ── Meerwerk (fase 9, migratie 031) ───────────────────────────────────────
// De planner ziet elke melding vóór de apotheek. Vrijgeven is de enige weg
// waarlangs er post naar een klant vertrekt; er is geen automatische verzending.

function requireClient() {
  if (!supabase) throw new Error('Supabase is niet geconfigureerd.');
  return supabase;
}

export async function getExtraWork(
  fromISO: string | null, toISO: string | null,
): Promise<ExtraWorkRow[]> {
  const sb = requireClient();
  const { data, error } = await sb.rpc('extra_work_overview', {
    p_from: fromISO, p_to: toISO,
  });
  if (error) throw error;
  return (data ?? []) as ExtraWorkRow[];
}

// Vrijgeven. plannerNote is wat de klant leest; leeg laten betekent dat de
// toelichting van de koerier ongewijzigd meegaat — een bewuste keuze, en daarom
// staat die tekst in het scherm al voorgevuld.
export async function releaseExtraWork(id: string, plannerNote: string | null): Promise<void> {
  const sb = requireClient();
  const { error } = await sb.rpc('extra_work_release', {
    p_id: id, p_planner_note: plannerNote,
  });
  if (error) throw error;
}

export async function reopenExtraWork(id: string): Promise<void> {
  const sb = requireClient();
  const { error } = await sb.rpc('extra_work_reopen', { p_id: id });
  if (error) throw error;
}

export const EXTRA_WORK_LABELS: Record<string, string> = {
  new:      'wacht op vrijgave',
  released: 'ligt bij de apotheek',
  approved: 'goedgekeurd',
  disputed: 'betwist',
  expired:  'geen reactie',
};

export const EXTRA_WORK_STYLES: Record<string, string> = {
  new:      'bg-amber-100 text-amber-800',
  released: 'bg-blue-100 text-blue-800',
  approved: 'bg-green-100 text-green-800',
  disputed: 'bg-red-100 text-red-800',
  // Bewust niet groen: verlopen wordt wél gefactureerd, maar er heeft nooit
  // iemand naar gekeken. Dat verschil met 'goedgekeurd' moet zichtbaar blijven.
  expired:  'bg-slate-200 text-slate-700',
};

// Minuten als '1:05'. In dit scherm staan uitloop en duur naast elkaar; een
// klokvorm leest dan rustiger dan '65 min'.
export function minutesText(minutes: number | null): string {
  if (minutes == null) return '—';
  const total = Math.round(Number(minutes));
  const h = Math.floor(Math.abs(total) / 60);
  const m = Math.abs(total) % 60;
  const sign = total < 0 ? '−' : '';
  return h === 0 ? `${sign}${m} min` : `${sign}${h}:${String(m).padStart(2, '0')}`;
}

// Hoeveel tijd er nog is om te reageren. Verstreken termijn geeft null; het
// scherm toont dan de status, niet een negatieve teller.
export function hoursLeft(respondBy: string | null): number | null {
  if (!respondBy) return null;
  const ms = new Date(respondBy).getTime() - Date.now();
  return ms > 0 ? Math.ceil(ms / 3_600_000) : null;
}
