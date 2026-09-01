import { supabase } from '../lib/supabase';
import { Employee, EmployeeImportResult } from '../types';

// ── Personeelsadministratie (fase 8, migratie 029) ────────────────────────
// Los van user_profiles: iemand kan hier staan zonder inlogaccount, en een
// verwijderd account haalt de rij niet weg. Lezen mag rechtstreeks (RLS laat
// alleen planners toe), schrijven loopt via de functies.

function requireClient() {
  if (!supabase) throw new Error('Supabase is niet geconfigureerd.');
  return supabase;
}

function toEmployee(r: any): Employee {
  return {
    id: r.id,
    personnelNumber: r.personnel_number ?? null,
    firstName: r.first_name,
    lastName: r.last_name,
    email: r.email ?? null,
    phone: r.phone ?? null,
    employmentType: r.employment_type ?? null,
    hourlyWage: r.hourly_wage != null ? Number(r.hourly_wage) : null,
    wageStartDate: r.wage_start_date ?? null,
    homePharmacyId: r.home_pharmacy_id ?? null,
    employedFrom: r.employed_from,
    employedUntil: r.employed_until ?? null,
    userProfileId: r.user_profile_id ?? null,
    note: r.note ?? null,
    isActive: r.is_active === true,
  };
}

// Uit de view, niet uit de tabel: is_active komt daar vandaan en die uitdrukking
// hoort niet nóg een keer in de frontend te staan.
export async function getEmployees(): Promise<Employee[]> {
  const sb = requireClient();
  const { data, error } = await sb
    .from('employees_active')
    .select('*')
    .order('last_name', { ascending: true })
    .order('first_name', { ascending: true });
  if (error) throw error;
  return (data ?? []).map(toEmployee);
}

export interface EmployeeInput {
  id?: string;
  personnel_number?: string | null;
  first_name: string;
  last_name: string;
  email?: string | null;
  phone?: string | null;
  employment_type?: string | null;
  hourly_wage?: string | null;
  wage_start_date?: string | null;
  home_pharmacy_id?: string | null;
  employed_from?: string | null;
  employed_until?: string | null;
  note?: string | null;
}

export async function saveEmployee(input: EmployeeInput): Promise<string> {
  const sb = requireClient();
  const { data, error } = await sb.rpc('employee_save', { p_employee: input });
  if (error) throw error;
  return data as string;
}

// Een inlogaccount koppelen of losmaken. Apart van saveEmployee(): dit raakt
// toegangsbeheer en hoort een bewuste handeling te zijn.
export async function linkProfile(employeeId: string, userProfileId: string | null): Promise<void> {
  const sb = requireClient();
  const { error } = await sb.rpc('employee_link_profile', {
    p_employee_id: employeeId, p_user_profile_id: userProfileId,
  });
  if (error) throw error;
}

export async function importEmployees(rows: Record<string, string>[]): Promise<EmployeeImportResult[]> {
  const sb = requireClient();
  const { data, error } = await sb.rpc('employee_import', { p_rows: rows });
  if (error) throw error;
  return (data ?? []) as EmployeeImportResult[];
}

// ── CSV ───────────────────────────────────────────────────────────────────
// Een eigen parser en geen bibliotheek: het gaat om één bestand met een handvol
// kolommen, en een afhankelijkheid erbij is meer onderhoud dan deze twintig
// regels. Quotes worden ondersteund omdat een achternaam een komma kan bevatten
// ("Vries, de" komt in exports voor).
export function parseCsv(text: string): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = '';
  let quoted = false;

  // Een BOM aan het begin van een Excel-export maakt de eerste kolomnaam
  // onherkenbaar; die gaat er hier af.
  const src = text.replace(/^﻿/, '');

  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    if (quoted) {
      if (c === '"') {
        if (src[i + 1] === '"') { field += '"'; i++; } else quoted = false;
      } else field += c;
      continue;
    }
    if (c === '"') { quoted = true; continue; }
    if (c === ',' || c === ';') { row.push(field); field = ''; continue; }
    if (c === '\r') continue;
    if (c === '\n') { row.push(field); rows.push(row); row = []; field = ''; continue; }
    field += c;
  }
  if (field !== '' || row.length > 0) { row.push(field); rows.push(row); }
  return rows.filter((r) => r.some((v) => v.trim() !== ''));
}

// Koppen uit de L1nda-export naar de velden van employee_import(). Meerdere
// schrijfwijzen per veld, want een export die je één keer per jaar ziet komt
// nooit precies zo terug als de vorige keer.
const HEADER_MAP: Record<string, string> = {
  personeelsnummer: 'personnel_number',
  'pers.nr': 'personnel_number',
  persnr: 'personnel_number',
  nummer: 'personnel_number',
  voornaam: 'first_name',
  achternaam: 'last_name',
  naam: 'last_name',
  email: 'email',
  'e-mail': 'email',
  telefoon: 'phone',
  telefoonnummer: 'phone',
  mobiel: 'phone',
  dienstverband: 'employment_type',
  contract: 'employment_type',
  uurloon: 'hourly_wage',
  loon: 'hourly_wage',
  'in dienst': 'employed_from',
  indienst: 'employed_from',
  startdatum: 'employed_from',
  'uit dienst': 'employed_until',
  uitdienst: 'employed_until',
  einddatum: 'employed_until',
};

export interface CsvParseResult {
  rows: Record<string, string>[];
  headers: string[];
  unmapped: string[];
}

// Zet een CSV om in rijen die employee_import() begrijpt. Onbekende kolommen
// worden niet stilzwijgend genegeerd maar teruggemeld, zodat een verkeerd
// gespelde kop opvalt vóór de import in plaats van erna.
export function csvToRows(text: string): CsvParseResult {
  const table = parseCsv(text);
  if (table.length === 0) return { rows: [], headers: [], unmapped: [] };

  const headers = table[0].map((h) => h.trim());
  const keys = headers.map((h) => HEADER_MAP[h.toLowerCase().trim()] ?? '');
  const unmapped = headers.filter((h, i) => h !== '' && keys[i] === '');

  const rows = table.slice(1).map((cells) => {
    const out: Record<string, string> = {};
    keys.forEach((k, i) => {
      if (!k) return;
      const v = (cells[i] ?? '').trim();
      if (v !== '') out[k] = v;
    });
    return out;
  }).filter((r) => (r.first_name ?? '') !== '' || (r.last_name ?? '') !== '');

  return { rows, headers, unmapped };
}

export function fullName(e: Employee): string {
  return `${e.firstName} ${e.lastName}`.trim();
}
