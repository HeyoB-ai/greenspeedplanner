import { Shift, ShiftStatus } from '../types';

// ── Conflictdetectie voor dubbel ingeplande koeriers (puur, los testbaar) ────
// (a) harde overlap: zelfde koerier, zelfde dag, tijdvensters overlappen.
// (b) zachte samenloop: zelfde koerier, zelfde dag, meerdere diensten, geen harde
//     overlap. Alleen diensten mét koerier tellen; twee verschillende koeriers of
//     open diensten zijn nooit een conflict.

export type ConflictLevel = 'none' | 'soft' | 'hard';

export interface ConflictOther {
  id: string;
  startTime: string;
  endTime: string | null;
  status: ShiftStatus;
  pharmacyIds: string[];
  level: 'soft' | 'hard';
}

export interface ShiftConflict {
  level: ConflictLevel;
  others: ConflictOther[];
  // Botst dit (hard) met een dienst die géén concept meer is (bevestigd →
  // koerier al geïnformeerd)? Dat is een ander geval dan concept-vs-concept.
  hardWithConfirmed: boolean;
}

const mins = (t: string) => {
  const [h, m] = t.split(':').map(Number);
  return h * 60 + m;
};

// Niveau tussen twee diensten van dezelfde koerier op dezelfde dag.
// Zonder eindtijd is alleen een gelijke starttijd hard; anders zacht.
export function pairLevel(a: Shift, b: Shift): 'soft' | 'hard' {
  const aS = mins(a.startTime), bS = mins(b.startTime);
  if (aS === bS) return 'hard';
  const aE = a.budgetedEndTime ? mins(a.budgetedEndTime) : null;
  const bE = b.budgetedEndTime ? mins(b.budgetedEndTime) : null;
  if (aE !== null && bE !== null) return aS < bE && bS < aE ? 'hard' : 'soft';
  if (aE !== null) return bS > aS && bS < aE ? 'hard' : 'soft';
  if (bE !== null) return aS > bS && aS < bE ? 'hard' : 'soft';
  return 'soft';
}

// Conflict-map (shiftId → ShiftConflict) over een set diensten.
export function detectConflicts(shifts: Shift[]): Map<string, ShiftConflict> {
  const byKey = new Map<string, Shift[]>();
  for (const s of shifts) {
    if (!s.courierId) continue;
    const k = `${s.courierId}|${s.shiftDate}`;
    const list = byKey.get(k) ?? [];
    list.push(s);
    byKey.set(k, list);
  }

  const result = new Map<string, ShiftConflict>();
  for (const group of byKey.values()) {
    if (group.length < 2) continue;
    for (const s of group) {
      const others: ConflictOther[] = [];
      let level: ConflictLevel = 'none';
      let hardWithConfirmed = false;
      for (const o of group) {
        if (o.id === s.id) continue;
        const lv = pairLevel(s, o);
        others.push({ id: o.id, startTime: o.startTime, endTime: o.budgetedEndTime, status: o.status, pharmacyIds: o.pharmacyIds, level: lv });
        if (lv === 'hard') {
          level = 'hard';
          if (o.status !== 'draft') hardWithConfirmed = true;
        } else if (level !== 'hard') {
          level = 'soft';
        }
      }
      result.set(s.id, { level, others, hardWithConfirmed });
    }
  }
  return result;
}
