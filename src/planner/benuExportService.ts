import * as XLSX from 'xlsx';
import { supabase } from '../lib/supabase';

// ── BENU-weekexports (fase 5, migratie 048) ───────────────────────────────
// Twee bestanden: één voor BENU HQ (rooster naast PDA) en één met de
// goedgekeurde extra tijd, per apotheek een tabblad voor de factuur.

function requireClient() {
  if (!supabase) throw new Error('Supabase is niet geconfigureerd.');
  return supabase;
}

interface RosterRow {
  shift_date: string;
  courier_name: string;
  pharmacy_name: string;
  start_time: string | null;
  budgeted_end_time: string | null;
  budgeted_minutes: number | null;
}

interface PdaRow {
  shift_date: string;
  courier_name: string;
  pharmacy_name: string;
  planned_minutes: number | null;
  pda_minutes: number | null;
  status: string;
}

interface ExtraRow {
  shift_date: string;
  courier_name: string;
  pharmacy_name: string;
  extra_minutes: number;
  extra_reason: string | null;
  status: string;
}

// ── Week ──────────────────────────────────────────────────────────────────

function toISO(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

// ISO-week: maandag is dag 1, en week 1 is de week met de eerste donderdag van
// het jaar. Daarom telt het jaar van de donderdag, niet van de gekozen datum —
// 29 december kan zo in week 1 van het volgende jaar vallen.
export function weekOf(dateISO: string): {
  isoWeek: number; year: number; from: string; to: string; parity: 'even' | 'odd';
} {
  const [y, m, d] = dateISO.split('-').map(Number);
  const date = new Date(y, m - 1, d);
  const dow = (date.getDay() + 6) % 7;   // 0 = maandag … 6 = zondag

  const monday = new Date(date);
  monday.setDate(date.getDate() - dow);
  const sunday = new Date(monday);
  sunday.setDate(monday.getDate() + 6);

  const thursday = new Date(monday);
  thursday.setDate(monday.getDate() + 3);
  const year = thursday.getFullYear();
  const jan1 = new Date(year, 0, 1);
  // Math.round vangt het uur verschil rond de zomertijdwissel op.
  const dayOfYear = Math.round((thursday.getTime() - jan1.getTime()) / 86_400_000);
  const isoWeek = Math.floor(dayOfYear / 7) + 1;

  return {
    isoWeek, year, from: toISO(monday), to: toISO(sunday),
    parity: isoWeek % 2 === 0 ? 'even' : 'odd',
  };
}

// ── RPC's ─────────────────────────────────────────────────────────────────

export async function getRosterWeek(from: string, to: string): Promise<RosterRow[]> {
  const sb = requireClient();
  const { data, error } = await sb.rpc('benu_roster_week', { p_from: from, p_to: to });
  if (error) throw error;
  return (data ?? []) as RosterRow[];
}

export async function getPdaWeek(from: string, to: string): Promise<PdaRow[]> {
  const sb = requireClient();
  const { data, error } = await sb.rpc('benu_pda_week', { p_from: from, p_to: to });
  if (error) throw error;
  return (data ?? []) as PdaRow[];
}

export async function getExtraWeek(from: string, to: string): Promise<ExtraRow[]> {
  const sb = requireClient();
  const { data, error } = await sb.rpc('benu_extra_week', { p_from: from, p_to: to });
  if (error) throw error;
  return (data ?? []) as ExtraRow[];
}

// ── Excel ─────────────────────────────────────────────────────────────────

export function isoDate(dateISO: string): string {
  return new Intl.DateTimeFormat('nl-NL', { weekday: 'short', day: 'numeric', month: 'short' })
    .format(new Date(dateISO + 'T00:00:00'));
}

function weekday(dateISO: string): string {
  return new Intl.DateTimeFormat('nl-NL', { weekday: 'long' }).format(new Date(dateISO + 'T00:00:00'));
}

// Excel staat maximaal 31 tekens toe en weigert : \ / ? * [ ] in een tabnaam.
function sheetName(name: string): string {
  return name.slice(0, 31).replace(/[:\\/?*[\]]/g, '-');
}

export function downloadBenuHqExcel(
  rows_a: RosterRow[], rows_b: PdaRow[], week: number, year: number,
): void {
  const wb = XLSX.utils.book_new();

  const roster = XLSX.utils.aoa_to_sheet([
    ['Datum', 'Weekdag', 'Koerier', 'Apotheek', 'Begintijd', 'Eindtijd', 'Min geroosterd'],
    ...rows_a.map((r) => [
      r.shift_date, weekday(r.shift_date), r.courier_name, r.pharmacy_name,
      r.start_time ?? '', r.budgeted_end_time ?? '', r.budgeted_minutes ?? '',
    ]),
  ]);
  XLSX.utils.book_append_sheet(wb, roster, 'Roostertijden');

  const pda = XLSX.utils.aoa_to_sheet([
    ['Datum', 'Weekdag', 'Koerier', 'Apotheek', 'Geplande min', 'PDA min', 'Status'],
    ...rows_b.map((r) => [
      r.shift_date, weekday(r.shift_date), r.courier_name, r.pharmacy_name,
      r.planned_minutes ?? '', r.pda_minutes ?? '', r.status,
    ]),
  ]);
  XLSX.utils.book_append_sheet(wb, pda, 'PDA-tijden');

  XLSX.writeFile(wb, `BENU-HQ-Week${week}-${year}.xlsx`);
}

export function downloadExtraExcel(rows: ExtraRow[], week: number, year: number): void {
  const wb = XLSX.utils.book_new();

  if (rows.length === 0) {
    XLSX.utils.book_append_sheet(
      wb,
      XLSX.utils.aoa_to_sheet([['Geen goedgekeurde extra tijd in deze week.']]),
      'Geen data',
    );
  } else {
    const byPharmacy = new Map<string, ExtraRow[]>();
    for (const r of rows) {
      const list = byPharmacy.get(r.pharmacy_name) ?? [];
      list.push(r);
      byPharmacy.set(r.pharmacy_name, list);
    }

    // Twee apotheeknamen die na afkappen gelijk worden, zouden hetzelfde
    // tabblad claimen; book_append_sheet gooit dan. Een volgnummer voorkomt dat.
    const used = new Set<string>();
    for (const name of [...byPharmacy.keys()].sort((a, b) => a.localeCompare(b, 'nl'))) {
      let tab = sheetName(name);
      for (let n = 2; used.has(tab.toLowerCase()); n++) {
        const suffix = ` (${n})`;
        tab = sheetName(name).slice(0, 31 - suffix.length) + suffix;
      }
      used.add(tab.toLowerCase());

      const sheet = XLSX.utils.aoa_to_sheet([
        ['Datum', 'Weekdag', 'Koerier', 'Extra min', 'Reden', 'Status'],
        ...byPharmacy.get(name)!.map((r) => [
          r.shift_date, weekday(r.shift_date), r.courier_name,
          r.extra_minutes, r.extra_reason ?? '', r.status,
        ]),
      ]);
      XLSX.utils.book_append_sheet(wb, sheet, tab);
    }
  }

  XLSX.writeFile(wb, `BENU-Extra-Week${week}-${year}.xlsx`);
}
