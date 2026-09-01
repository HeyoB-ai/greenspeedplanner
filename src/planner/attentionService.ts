import { supabase } from '../lib/supabase';

// ── Wat er op de planner ligt te wachten ──────────────────────────────────
// Voor de telbadge op het menu Financieel (migraties 033 en 034). Eén aanroep;
// de volledige overzichten ophalen om er tellingen uit te halen zou bij elke
// verversing alle declaraties over de lijn trekken.
//
// Betwistingen tellen mee én komen apart terug: er staat geld open bij iemand
// die het er niet mee eens is, en dat vraagt iets anders dan een stapel te
// beoordelen declaraties.
//
// De telling zit in de database en niet hier: wát meetelt is een afspraak
// (ingediend, nog niet vrijgegeven) die bij de statussen hoort en niet bij het
// scherm dat hem toevallig toont.

export type Attention = {
  declarations: number;            // ingediend of betwist
  declarationsDisputed: number;    // waarvan betwist
  extraWork: number;               // gemeld of betwist
  extraWorkDisputed: number;       // waarvan betwist
  disputed: number;                // de twee betwistingen samen
  total: number;
};

export const NO_ATTENTION: Attention = {
  declarations: 0, declarationsDisputed: 0,
  extraWork: 0, extraWorkDisputed: 0,
  disputed: 0, total: 0,
};

export async function getAttention(): Promise<Attention> {
  if (!supabase) return NO_ATTENTION;
  const { data, error } = await supabase.rpc('planner_attention');
  if (error) throw error;
  // De betwiste velden komen uit migratie 034. Draait die nog niet, dan
  // ontbreken ze en blijven ze nul — de badge telt dan zoals in 033.
  const row = (Array.isArray(data) ? data[0] : data) as
    | {
        declarations_to_review: number;
        declarations_disputed?: number;
        extra_work_to_release: number;
        extra_work_disputed?: number;
        total: number;
      }
    | undefined;
  if (!row) return NO_ATTENTION;
  const declarationsDisputed = row.declarations_disputed ?? 0;
  const extraWorkDisputed = row.extra_work_disputed ?? 0;
  return {
    declarations: row.declarations_to_review ?? 0,
    declarationsDisputed,
    extraWork: row.extra_work_to_release ?? 0,
    extraWorkDisputed,
    disputed: declarationsDisputed + extraWorkDisputed,
    total: row.total ?? 0,
  };
}
