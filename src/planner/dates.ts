// Datumhelpers — week begint op maandag. Alle DB-datums zijn 'YYYY-MM-DD'
// (lokale kalenderdatum, geen tijdzone-conversie).

export function toISODate(d: Date): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}

export function parseISODate(s: string): Date {
  const [y, m, d] = s.split('-').map(Number);
  return new Date(y, m - 1, d);
}

// Maandag van de week waarin `d` valt.
export function startOfWeek(d: Date): Date {
  const copy = new Date(d.getFullYear(), d.getMonth(), d.getDate());
  const dow = (copy.getDay() + 6) % 7; // 0 = maandag
  copy.setDate(copy.getDate() - dow);
  return copy;
}

export function addDays(d: Date, n: number): Date {
  const copy = new Date(d);
  copy.setDate(copy.getDate() + n);
  return copy;
}

// De 7 dagen (ma..zo) van de week vanaf `weekStart`.
export function weekDays(weekStart: Date): Date[] {
  return Array.from({ length: 7 }, (_, i) => addDays(weekStart, i));
}

// ISO-weeknummer, voor de kop.
export function isoWeekNumber(d: Date): number {
  const date = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()));
  const dayNum = (date.getUTCDay() + 6) % 7;
  date.setUTCDate(date.getUTCDate() - dayNum + 3);
  const firstThursday = new Date(Date.UTC(date.getUTCFullYear(), 0, 4));
  const diff = date.getTime() - firstThursday.getTime();
  return 1 + Math.round(diff / (7 * 24 * 3600 * 1000));
}

// 'HH:MM:SS' of 'HH:MM' → 'HH:MM'
export function shortTime(t: string | null): string {
  if (!t) return '';
  return t.slice(0, 5);
}

export function formatDayHeader(d: Date): string {
  return `${d.getDate()}/${d.getMonth() + 1}`;
}
