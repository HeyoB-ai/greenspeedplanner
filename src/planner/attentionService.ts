import { supabase } from '../lib/supabase';

// ── Wat er op de planner ligt te wachten ──────────────────────────────────
// Voor de telbadge op het menu Financieel (migratie 033). Twee getallen uit één
// aanroep; de volledige overzichten ophalen om er twee tellingen uit te halen
// zou bij elke verversing alle declaraties over de lijn trekken.
//
// De telling zit in de database en niet hier: wát meetelt is een afspraak
// (ingediend, nog niet vrijgegeven) die bij de statussen hoort en niet bij het
// scherm dat hem toevallig toont.

export type Attention = {
  declarations: number;   // ingediend, wacht op beoordeling
  extraWork: number;      // gemeld, wacht op vrijgave
  total: number;
};

export const NO_ATTENTION: Attention = { declarations: 0, extraWork: 0, total: 0 };

export async function getAttention(): Promise<Attention> {
  if (!supabase) return NO_ATTENTION;
  const { data, error } = await supabase.rpc('planner_attention');
  if (error) throw error;
  const row = (Array.isArray(data) ? data[0] : data) as
    | { declarations_to_review: number; extra_work_to_release: number; total: number }
    | undefined;
  if (!row) return NO_ATTENTION;
  return {
    declarations: row.declarations_to_review ?? 0,
    extraWork: row.extra_work_to_release ?? 0,
    total: row.total ?? 0,
  };
}
