import { supabase } from '../lib/supabase';
import { BenuOverviewRow } from '../types';

// ── BENU-invoer (fase 4, migratie 047) ────────────────────────────────────
// Alleen lezen. Wat de koerier opgaf en wat de apotheek ervan vond; de planner
// grijpt hier niet in, dat loopt via de mails en de 48-uurstermijn.

function requireClient() {
  if (!supabase) throw new Error('Supabase is niet geconfigureerd.');
  return supabase;
}

export async function getBenuOverview(fromISO: string, toISO: string): Promise<BenuOverviewRow[]> {
  const sb = requireClient();
  const { data, error } = await sb.rpc('benu_entries_overview', {
    p_from: fromISO, p_to: toISO,
  });
  if (error) throw error;
  return (data ?? []) as BenuOverviewRow[];
}

export const BENU_STATUS_LABELS: Record<string, string> = {
  pending:       'Wacht op koerier',
  no_extra:      'Geen extra',
  submitted:     'Ingediend',
  approved:      'Goedgekeurd',
  disputed:      'Betwist',
  auto_approved: 'Auto-goedgekeurd',
};

export const BENU_STATUS_STYLES: Record<string, string> = {
  pending:       'bg-amber-100 text-amber-800',
  no_extra:      'bg-slate-100 text-slate-600',
  submitted:     'bg-blue-100 text-blue-800',
  approved:      'bg-green-100 text-green-800',
  disputed:      'bg-red-100 text-red-800',
  auto_approved: 'bg-emerald-100 text-emerald-700',
};
