import { supabase } from '../lib/supabase';
import { EXTRA_WORK_LABELS } from './extraWorkService';

// ── Logboek (migratie 056) ────────────────────────────────────────────────
// Lezen gaat uitsluitend via audit_log_list(); de tabel zelf staat dicht. De
// functie controleert op superuser en geeft anders een fout — het scherm hoeft
// daar dus niet zelf op te vertrouwen.
//
// Het meeste werk hier is vertalen. De database bewaart "shifts, UPDATE,
// status: draft → planned"; een planner wil lezen "Heyo bevestigde dienst di
// 6-10 12:00 Erik Suyderhoud". Elke zin valt terug op tabel, actie en velden,
// zodat er nooit een lege regel staat — een regel die niets zegt is in een
// logboek erger dan een lelijke.

function requireClient() {
  if (!supabase) throw new Error('Supabase is niet geconfigureerd.');
  return supabase;
}

export type AuditSource = 'app' | 'formulier' | 'service' | 'cron' | 'sql' | 'onbekend';
export type AuditAction = 'INSERT' | 'UPDATE' | 'DELETE';
type Data = Record<string, unknown> | null;

export interface AuditRow {
  id: number;
  occurred_at: string;
  txid: number;
  tx_total: number;               // regels van dezelfde transactie binnen de filters
  actor_id: string | null;
  actor_name: string | null;
  actor_role: string | null;
  source: AuditSource;
  app_name: string | null;
  table_name: string;
  action: AuditAction;
  row_id: string | null;
  shift_id: string | null;
  courier_id: string | null;
  courier_name: string | null;
  old_courier_name: string | null; // alleen als courier_id zelf wijzigde
  pharmacy_name: string | null;
  shift_date: string | null;       // 'YYYY-MM-DD', ook van een verwijderde dienst
  shift_start: string | null;      // 'HH:MM'
  shift_pharmacy_names: string | null;
  old_data: Data;
  new_data: Data;
  changed_fields: string[] | null;
}

export interface AuditActor {
  actor_id: string;
  actor_name: string | null;
  actor_role: string | null;
  regels: number;
}

// ── Soorten ──────────────────────────────────────────────────────────────
// Elke gelogde tabel hoort bij precies één soort. Staat een tabel nergens, dan
// verdwijnt hij uit beeld zodra iemand op soort filtert — en dat merkt niemand.
export type AuditKind =
  | 'dienst' | 'rooster' | 'medewerker' | 'tarief'
  | 'declaratie' | 'meerwerk' | 'benu' | 'instelling';

export const KIND_TABLES: Record<AuditKind, string[]> = {
  dienst:     ['shifts', 'shift_pharmacies', 'shift_institutions'],
  rooster:    ['pharmacy_schedules', 'schedule_exceptions', 'holidays'],
  medewerker: ['employees', 'courier_contacts', 'user_profiles', 'courier_pharmacy_access', 'courier_distances'],
  tarief:     ['pharmacy_rates', 'reimbursement_rates'],
  declaratie: ['shift_declarations', 'declaration_expenses'],
  meerwerk:   ['extra_work'],
  benu:       ['benu_shift_entries', 'benu_pharmacy_entries'],
  // Instellingen en de stamgegevens die met de bezorg-app gedeeld worden: wat
  // je zelden aanraakt en wat, als het verandert, overal doorwerkt.
  instelling: ['declaration_settings', 'invoice_settings', 'pharmacies', 'institutions', 'groups'],
};

export const KIND_LABELS: Record<AuditKind, string> = {
  dienst: 'Dienst', rooster: 'Rooster', medewerker: 'Medewerker', tarief: 'Tarief',
  declaratie: 'Declaratie', meerwerk: 'Meerwerk', benu: 'BENU', instelling: 'Instelling',
};

// ── Ophalen ──────────────────────────────────────────────────────────────
export const PAGE_SIZE = 100;

export interface AuditFilters {
  from: string;          // 'YYYY-MM-DD', inclusief
  to: string;            // 'YYYY-MM-DD', inclusief
  kind: AuditKind | '';
  who: string;           // '' = iedereen, 'sql' = buiten de Planner om, anders een actor_id
  courierId: string;     // '' = alle koeriers
  search: string;
  showCouriers: boolean; // koeriers en formulieren
  showSystem: boolean;   // service en cron
}

// Een dag in de tijdzone van de planner, niet in UTC. Anders valt wat iemand om
// half één 's nachts deed op de verkeerde dag.
function startOfDay(iso: string, plusDays = 0): string {
  const [y, m, d] = iso.split('-').map(Number);
  return new Date(y, m - 1, d + plusDays).toISOString();
}

export async function getAuditLog(f: AuditFilters, beforeId: number | null): Promise<AuditRow[]> {
  const sb = requireClient();
  const { data, error } = await sb.rpc('audit_log_list', {
    p_from: startOfDay(f.from),
    p_to: startOfDay(f.to, 1),
    p_tables: f.kind ? KIND_TABLES[f.kind] : null,
    p_actor: f.who && f.who !== 'sql' ? f.who : null,
    p_source: f.who === 'sql' ? 'sql' : null,
    p_courier: f.courierId || null,
    p_search: f.search.trim() || null,
    p_couriers: f.showCouriers,
    p_system: f.showSystem,
    p_before_id: beforeId,
    p_limit: PAGE_SIZE,
  });
  if (error) throw error;
  return (data ?? []) as AuditRow[];
}

export async function getAuditActors(from: string, to: string): Promise<AuditActor[]> {
  const sb = requireClient();
  const { data, error } = await sb.rpc('audit_log_actors', {
    p_from: startOfDay(from), p_to: startOfDay(to, 1),
  });
  if (error) throw error;
  return (data ?? []) as AuditActor[];
}

// ── Groeperen per transactie ─────────────────────────────────────────────
// Eén klik is één transactie. "Bevestig alles" zijn tien regels in de tabel maar
// één handeling van een mens, en zo hoort hij ook in het logboek te staan.
export interface AuditGroup {
  txid: number;
  rows: AuditRow[];   // nieuwste eerst
  total: number;      // hoeveel regels de transactie binnen de filters telt
}

export function groupByTx(rows: AuditRow[]): AuditGroup[] {
  const map = new Map<number, AuditGroup>();
  const order: AuditGroup[] = [];
  for (const r of rows) {
    let g = map.get(r.txid);
    if (!g) {
      g = { txid: r.txid, rows: [], total: 0 };
      map.set(r.txid, g);
      order.push(g);
    }
    g.rows.push(r);
    g.total = Math.max(g.total, Number(r.tx_total));
  }
  return order;
}

// ── Wie ──────────────────────────────────────────────────────────────────
const PLANNER_ROLES = ['superuser', 'supervisor', 'admin'];

export type ActorTone = 'planner' | 'courier' | 'system' | 'sql' | 'unknown';

export function actorOf(r: AuditRow): { text: string; tone: ActorTone } {
  switch (r.source) {
    case 'app':
      return {
        text: r.actor_name ?? 'onbekende gebruiker',
        tone: PLANNER_ROLES.includes(r.actor_role ?? '') ? 'planner' : 'courier',
      };
    case 'formulier': return { text: 'via formulier', tone: 'courier' };
    case 'service':   return { text: 'systeem', tone: 'system' };
    case 'cron':      return { text: 'systeem (cron)', tone: 'system' };
    // Geen naam, want die is er niet: dat is precies het punt.
    case 'sql':       return { text: 'buiten de Planner om (SQL)', tone: 'sql' };
    default:          return { text: 'onbekende bron', tone: 'unknown' };
  }
}

// ── Opmaak van waarden ───────────────────────────────────────────────────
const WEEKDAYS = ['zo', 'ma', 'di', 'wo', 'do', 'vr', 'za'];

// 'YYYY-MM-DD' → 'di 6-10'. Als losse getallen aan Date, zodat de tijdzone de
// dag niet kan verschuiven.
export function dateShort(iso: string): string {
  const [y, m, d] = iso.slice(0, 10).split('-').map(Number);
  return `${WEEKDAYS[new Date(y, m - 1, d).getDay()]} ${d}-${m}`;
}

export function timestampShort(iso: string): string {
  const t = new Date(iso);
  const hh = String(t.getHours()).padStart(2, '0');
  const mm = String(t.getMinutes()).padStart(2, '0');
  return `${WEEKDAYS[t.getDay()]} ${t.getDate()}-${t.getMonth() + 1} ${hh}:${mm}`;
}

// De termen van de Planner, niet die van de database.
const SHIFT_STATUS: Record<string, string> = {
  draft: 'concept', planned: 'bevestigd', offered: 'aangeboden', claimed: 'geclaimd', assigned: 'toegewezen',
};
const DECLARATION_STATUS: Record<string, string> = {
  open: 'open', submitted: 'ingediend', approved: 'goedgekeurd', disputed: 'betwist', expired: 'verlopen',
};
const TRANSPORT: Record<string, string> = { bike: 'fiets', car: 'auto' };

function statusLabel(table: string, v: string): string {
  if (table === 'shifts') return SHIFT_STATUS[v] ?? v;
  if (table === 'shift_declarations') return DECLARATION_STATUS[v] ?? v;
  if (table === 'extra_work') return EXTRA_WORK_LABELS[v] ?? v;
  return v;
}

const FIELD_LABELS: Record<string, string> = {
  status: 'status', shift_date: 'datum', start_time: 'begintijd', budgeted_end_time: 'eindtijd',
  courier_id: 'koerier', sick_leave: 'ziek', transport_mode: 'vervoer', car_is_own: 'eigen auto',
  shift_type: 'soort dienst', confirmed_at: 'bevestigd op', confirmed_by: 'bevestigd door',
  created_at: 'aangemaakt op', created_by: 'aangemaakt door', note: 'notitie', notes: 'notitie',
  name: 'naam', role: 'rol', phone: 'telefoon', phone_e164: 'telefoon', email_override: 'e-mailadres',
  city: 'plaats', billing_email: 'factuuradres', is_benu_selfbilling: 'BENU selfbilling',
  actual_start: 'werkelijk begin', actual_end: 'werkelijk eind', pda_start: 'PDA begin', pda_end: 'PDA eind',
  courier_note: 'toelichting koerier', planner_note: 'tekst voor apotheek', review_note: 'bericht planning',
  claims_travel: 'reiskosten', own_car_km: 'kilometers', share_minutes: 'extra minuten',
  extra_minutes: 'extra minuten', hourly_rate: 'uurtarief', valid_from: 'geldig vanaf',
  description: 'omschrijving', amount_eur: 'bedrag', holiday_date: 'datum', pharmacy_id: 'apotheek',
  weekday: 'weekdag', is_active: 'actief',
};

export function fieldLabel(field: string): string {
  return FIELD_LABELS[field] ?? field.replace(/_/g, ' ');
}

// Velden die bij een wijziging meeveranderen zonder dat iemand ze koos. In het
// uitgeklapte overzicht staan ze gewoon; in de zin zouden ze alleen ruis zijn.
const HUISHOUDELIJK = new Set(['confirmed_at', 'confirmed_by', 'created_at', 'created_by', 'updated_at']);

// Velden met het id van een gebruiker. Een uuid zegt een planner niets; meestal
// is het degene die de wijziging deed, en dan weten we de naam al.
const USER_FIELDS = new Set(['confirmed_by', 'created_by', 'released_by', 'reviewed_by']);

export function valueText(r: AuditRow, field: string, v: unknown, side: 'old' | 'new'): string {
  if (v === null || v === undefined || v === '') return '—';
  if (field === 'courier_id') {
    const name = side === 'new' ? r.courier_name : r.old_courier_name;
    return name ?? 'andere koerier';
  }
  if (USER_FIELDS.has(field) && typeof v === 'string') {
    return v === r.actor_id ? (r.actor_name ?? 'deze gebruiker') : 'andere gebruiker';
  }
  if (field === 'status' && typeof v === 'string') return statusLabel(r.table_name, v);
  if (field === 'transport_mode' && typeof v === 'string') return TRANSPORT[v] ?? v;
  if (typeof v === 'boolean') return v ? 'ja' : 'nee';
  if (typeof v === 'string') {
    if (/^\d{2}:\d{2}(:\d{2})?$/.test(v)) return v.slice(0, 5);
    if (/^\d{4}-\d{2}-\d{2}$/.test(v)) return dateShort(v);
    if (/^\d{4}-\d{2}-\d{2}T/.test(v)) return timestampShort(v);
    return v;
  }
  if (typeof v === 'object') return JSON.stringify(v);
  return String(v);
}

// De velden die een rij laat zien als hij wordt uitgeklapt: bij een wijziging
// wat veranderde, bij aanmaken en verwijderen de hele rij zonder lege velden.
export function diffFields(r: AuditRow): { field: string; old: string; new: string }[] {
  const keys = r.action === 'UPDATE'
    ? (r.changed_fields ?? [])
    : Object.keys((r.action === 'INSERT' ? r.new_data : r.old_data) ?? {})
        .filter((k) => {
          const v = (r.action === 'INSERT' ? r.new_data : r.old_data)?.[k];
          return v !== null && v !== undefined && v !== '';
        });
  return keys.map((k) => ({
    field: k,
    old: r.action === 'INSERT' ? '' : valueText(r, k, r.old_data?.[k], 'old'),
    new: r.action === 'DELETE' ? '' : valueText(r, k, r.new_data?.[k], 'new'),
  }));
}

// ── Zinnen ───────────────────────────────────────────────────────────────
const NOUN: Record<string, [string, string]> = {
  shifts:                  ['dienst', 'diensten'],
  shift_pharmacies:        ['apotheek op een dienst', 'apotheken op diensten'],
  shift_institutions:      ['bestemming op een dienst', 'bestemmingen op diensten'],
  pharmacy_schedules:      ['roosterregel', 'roosterregels'],
  schedule_exceptions:     ['roosteruitzondering', 'roosteruitzonderingen'],
  holidays:                ['feestdag', 'feestdagen'],
  employees:               ['medewerker', 'medewerkers'],
  courier_contacts:        ['contactgegevens', 'contactgegevens'],
  user_profiles:           ['gebruikersprofiel', 'gebruikersprofielen'],
  courier_pharmacy_access: ['apotheektoegang', 'apotheektoegangen'],
  courier_distances:       ['reisafstand', 'reisafstanden'],
  pharmacies:              ['apotheek', 'apotheken'],
  institutions:            ['bestemming', 'bestemmingen'],
  groups:                  ['keten', 'ketens'],
  pharmacy_rates:          ['apotheektarief', 'apotheektarieven'],
  reimbursement_rates:     ['vergoedingstarief', 'vergoedingstarieven'],
  declaration_settings:    ['declaratie-instelling', 'declaratie-instellingen'],
  invoice_settings:        ['factuurinstelling', 'factuurinstellingen'],
  shift_declarations:      ['declaratie', 'declaraties'],
  declaration_expenses:    ['onkostenpost', 'onkostenposten'],
  extra_work:              ['meerwerkmelding', 'meerwerkmeldingen'],
  benu_shift_entries:      ['BENU-invoer', 'BENU-invoeren'],
  benu_pharmacy_entries:   ['BENU-reactie van een apotheek', 'BENU-reacties van apotheken'],
};

function noun(table: string, plural = false): string {
  const n = NOUN[table];
  return n ? n[plural ? 1 : 0] : table;
}

const str = (d: Data, k: string): string | null => {
  const v = d?.[k];
  return v === null || v === undefined || v === '' ? null : String(v);
};

// 'di 6-10 12:00 Erik Suyderhoud' — zoveel als er bekend is.
function shiftDesc(r: AuditRow, withCourier = true): string {
  return [
    r.shift_date ? dateShort(r.shift_date) : null,
    r.shift_start,
    withCourier ? r.courier_name : null,
  ].filter(Boolean).join(' ');
}

function bijDienst(r: AuditRow): string {
  const d = shiftDesc(r);
  return d ? ` bij dienst ${d}` : '';
}

// "wijzigde eindtijd van 16:00 naar 17:30" voor een kort veld, en anders alleen
// welk veld — een toelichting van drie regels hoort in het uitgeklapte overzicht,
// niet in de zin.
function fieldChange(r: AuditRow, f: string): string {
  const o = valueText(r, f, r.old_data?.[f], 'old');
  const n = valueText(r, f, r.new_data?.[f], 'new');
  return o.length <= 24 && n.length <= 24
    ? `wijzigde ${fieldLabel(f)} van ${o} naar ${n}`
    : `wijzigde ${fieldLabel(f)}`;
}

// Hetzelfde, maar met erbij wélk ding: "wijzigde plaats van BENU Apotheek De Eng
// naar Zeist (was Eng)". Met het ding erin past "van … naar …" niet meer — dan
// staat er twee keer "van" en leest niemand meer welk deel waarbij hoort.
function fieldChangeOf(r: AuditRow, f: string, wat: string): string {
  const o = valueText(r, f, r.old_data?.[f], 'old');
  const n = valueText(r, f, r.new_data?.[f], 'new');
  return o.length <= 24 && n.length <= 24
    ? `wijzigde ${fieldLabel(f)} van ${wat} naar ${n} (was ${o})`
    : `wijzigde ${fieldLabel(f)} van ${wat}`;
}

function inhoudelijk(r: AuditRow): string[] {
  return (r.changed_fields ?? []).filter((f) => !HUISHOUDELIJK.has(f));
}

function generic(r: AuditRow): string {
  if (r.action === 'INSERT') return `maakte ${noun(r.table_name)} aan`;
  if (r.action === 'DELETE') return `verwijderde ${noun(r.table_name)}`;
  const fields = inhoudelijk(r);
  if (fields.length === 0) return `wijzigde ${noun(r.table_name)}`;
  if (fields.length === 1) return fieldChangeOf(r, fields[0], `een ${noun(r.table_name)}`);
  return `wijzigde ${noun(r.table_name)} (${fields.map(fieldLabel).join(', ')})`;
}

const SENTENCES: Record<string, (r: AuditRow) => string | null> = {
  shifts: (r) => {
    const dienst = `dienst ${shiftDesc(r)}`.trim();
    if (r.action === 'INSERT') {
      return str(r.new_data, 'status') === 'draft' ? `maakte ${dienst} aan als concept` : `maakte ${dienst} aan`;
    }
    if (r.action === 'DELETE') return `verwijderde ${dienst}`;

    const fields = inhoudelijk(r);
    const lead: string[] = [];
    const rest: string[] = [];
    for (const f of fields) {
      if (f === 'status') {
        const o = str(r.old_data, 'status');
        const n = str(r.new_data, 'status');
        if (o === 'draft' && n === 'planned') lead.push(`bevestigde ${dienst}`);
        else if (n === 'draft') lead.push(`zette ${dienst} terug naar concept`);
        else lead.push(`zette ${dienst} van ${statusLabel('shifts', o ?? '—')} op ${statusLabel('shifts', n ?? '—')}`);
      } else if (f === 'sick_leave') {
        lead.push(r.new_data?.sick_leave ? `meldde ziek voor ${dienst}` : `trok de ziekmelding in voor ${dienst}`);
      } else if (f === 'courier_id') {
        const zonder = `dienst ${shiftDesc(r, false)}`.trim();
        lead.push(r.new_data?.courier_id
          ? `wees ${zonder} toe aan ${r.courier_name ?? 'een koerier'}`
            + (r.old_courier_name ? ` (was ${r.old_courier_name})` : '')
          : `haalde ${r.old_courier_name ?? 'de koerier'} van ${zonder}`);
      } else if (f === 'shift_date') {
        rest.push(`verplaatste de dienst van ${valueText(r, f, r.old_data?.[f], 'old')} naar ${valueText(r, f, r.new_data?.[f], 'new')}`);
      } else {
        rest.push(fieldChange(r, f));
      }
    }
    if (lead.length > 0) return [...lead, ...rest].join(', ');
    if (rest.length > 0) return rest.join(', ') + bijDienst(r);
    return null;
  },

  shift_pharmacies: (r) => {
    const ap = r.pharmacy_name ?? 'een apotheek';
    const d = shiftDesc(r);
    if (r.action === 'INSERT') return `voegde ${ap} toe aan dienst ${d}`.trim();
    if (r.action === 'DELETE') return `haalde ${ap} van dienst ${d}`.trim();
    return null;
  },

  shift_institutions: (r) => {
    if (r.action === 'INSERT') return `voegde een bestemming toe${bijDienst(r)}`;
    if (r.action === 'DELETE') return `haalde een bestemming weg${bijDienst(r)}`;
    return null;
  },

  shift_declarations: (r) => {
    if (r.action === 'INSERT') return `maakte declaratie aan${bijDienst(r)}`;
    if (r.action === 'DELETE') return `verwijderde declaratie${bijDienst(r)}`;
    if ((r.changed_fields ?? []).includes('status')) {
      const n = str(r.new_data, 'status');
      const verb = {
        approved: 'keurde declaratie goed', disputed: 'betwistte declaratie',
        submitted: 'diende declaratie in', open: 'zette declaratie terug naar open',
      }[n ?? ''] ?? `zette declaratie op ${statusLabel('shift_declarations', n ?? '—')}`;
      return verb + bijDienst(r);
    }
    return null;
  },

  declaration_expenses: (r) => {
    const d = r.action === 'DELETE' ? r.old_data : r.new_data;
    const wat = [str(d, 'description'), str(d, 'amount_eur') ? `€ ${Number(str(d, 'amount_eur')).toFixed(2).replace('.', ',')}` : null]
      .filter(Boolean).join(' ');
    if (r.action === 'INSERT') return `voegde onkostenpost toe${wat ? `: ${wat}` : ''}${bijDienst(r)}`;
    if (r.action === 'DELETE') return `verwijderde onkostenpost${wat ? ` ${wat}` : ''}${bijDienst(r)}`;
    return null;
  },

  extra_work: (r) => {
    const ap = r.pharmacy_name ? ` voor ${r.pharmacy_name}` : '';
    if (r.action === 'INSERT') {
      const min = str(r.new_data, 'share_minutes');
      return `zette meerwerk klaar${min ? ` (${Math.round(Number(min))} min)` : ''}${ap}${bijDienst(r)}`;
    }
    if (r.action === 'UPDATE' && (r.changed_fields ?? []).includes('status')) {
      const n = str(r.new_data, 'status');
      const verb = {
        released: 'gaf meerwerk vrij', approved: 'meerwerk goedgekeurd door de apotheek',
        disputed: 'meerwerk betwist door de apotheek', expired: 'meerwerk verliep zonder reactie',
        new: 'zette meerwerk terug naar wacht op vrijgave',
      }[n ?? ''];
      if (verb) return verb + ap + bijDienst(r);
    }
    return null;
  },

  holidays: (r) => {
    const d = r.action === 'DELETE' ? r.old_data : r.new_data;
    const wat = [str(d, 'name'), str(d, 'holiday_date') ? dateShort(str(d, 'holiday_date')!) : null].filter(Boolean).join(' ');
    if (r.action === 'INSERT') return `voegde feestdag toe${wat ? `: ${wat}` : ''}`;
    if (r.action === 'DELETE') return `verwijderde feestdag${wat ? ` ${wat}` : ''}`;
    return null;
  },

  employees: (r) => {
    const naam = str(r.new_data, 'name') ?? str(r.old_data, 'name');
    if (r.action === 'INSERT') return `nam medewerker${naam ? ` ${naam}` : ''} op`;
    if (r.action === 'DELETE') return `verwijderde medewerker${naam ? ` ${naam}` : ''}`;
    return null;
  },

  courier_contacts: (r) => {
    const fields = inhoudelijk(r);
    const wie = r.courier_name ?? 'een koerier';
    if (r.action === 'UPDATE' && fields.length > 0) {
      return `wijzigde ${fields.map(fieldLabel).join(', ')} van ${wie}`;
    }
    if (r.action === 'INSERT') return `legde contactgegevens vast van ${wie}`;
    return null;
  },

  user_profiles: (r) => {
    const wie = r.courier_name ?? 'een gebruiker';
    if (r.action === 'UPDATE' && (r.changed_fields ?? []).includes('role')) {
      return `wijzigde de rol van ${wie} van ${str(r.old_data, 'role') ?? '—'} naar ${str(r.new_data, 'role') ?? '—'}`;
    }
    if (r.action === 'UPDATE') {
      const fields = inhoudelijk(r);
      if (fields.length > 0) return `wijzigde ${fields.map(fieldLabel).join(', ')} van ${wie}`;
    }
    if (r.action === 'INSERT') return `maakte gebruikersprofiel aan voor ${wie}`;
    if (r.action === 'DELETE') return `verwijderde gebruikersprofiel van ${wie}`;
    return null;
  },

  courier_pharmacy_access: (r) => {
    const wie = r.courier_name ?? 'een koerier';
    const ap = r.pharmacy_name ?? 'een apotheek';
    if (r.action === 'INSERT') return `gaf ${wie} toegang tot ${ap}`;
    if (r.action === 'DELETE') return `trok de toegang van ${wie} tot ${ap} in`;
    return null;
  },

  courier_distances: (r) => {
    const wie = r.courier_name ?? 'een koerier';
    const ap = r.pharmacy_name ? ` tot ${r.pharmacy_name}` : '';
    if (r.action === 'UPDATE') {
      const fields = inhoudelijk(r);
      if (fields.length === 1) return fieldChangeOf(r, fields[0], `${wie}${ap}`);
    }
    if (r.action === 'INSERT') return `legde de reisafstand vast van ${wie}${ap}`;
    if (r.action === 'DELETE') return `verwijderde de reisafstand van ${wie}${ap}`;
    return `wijzigde de reisafstand van ${wie}${ap}`;
  },

  pharmacies: (r) => {
    const naam = r.pharmacy_name ?? 'een apotheek';
    if (r.action === 'UPDATE') {
      const fields = inhoudelijk(r);
      if (fields.length === 1) return fieldChangeOf(r, fields[0], naam);
      if (fields.length > 1) return `wijzigde ${naam} (${fields.map(fieldLabel).join(', ')})`;
    }
    if (r.action === 'INSERT') return `voegde apotheek ${naam} toe`;
    if (r.action === 'DELETE') return `verwijderde apotheek ${naam}`;
    return null;
  },

  pharmacy_rates: (r) => {
    const ap = r.pharmacy_name ? ` van ${r.pharmacy_name}` : '';
    if (r.action === 'INSERT') return `stelde een tarief in${ap}`;
    if (r.action === 'DELETE') return `verwijderde een tarief${ap}`;
    const fields = inhoudelijk(r);
    return fields.length === 1 ? fieldChangeOf(r, fields[0], r.pharmacy_name ?? 'een apotheek') : null;
  },

  pharmacy_schedules: (r) => {
    const ap = r.pharmacy_name ? ` van ${r.pharmacy_name}` : '';
    if (r.action === 'INSERT') return `voegde een roosterregel toe${ap}`;
    if (r.action === 'DELETE') return `verwijderde een roosterregel${ap}`;
    return `wijzigde het rooster${ap}`;
  },
};

// De zin bij één regel. Nooit leeg: kent een tabel geen eigen zin, of past de
// wijziging in geen van de gevallen, dan tabel, actie en velden.
export function rowSentence(r: AuditRow): string {
  let s: string | null = null;
  try {
    s = SENTENCES[r.table_name]?.(r) ?? null;
  } catch {
    s = null;   // een onverwachte vorm in old_data mag het scherm niet breken
  }
  return s && s.trim() ? s : generic(r);
}

// Een sleutel voor "dezelfde handeling". Alleen regels met dezelfde sleutel
// mogen samen één meervoudige zin krijgen.
function verbKey(r: AuditRow): string {
  if (r.action !== 'UPDATE') return `${r.table_name}|${r.action}`;
  const f = inhoudelijk(r);
  if (f.includes('status')) return `${r.table_name}|status:${str(r.new_data, 'status')}`;
  if (f.includes('sick_leave')) return `${r.table_name}|sick:${r.new_data?.sick_leave}`;
  return `${r.table_name}|UPDATE`;
}

const PLURAL: Record<string, (n: number) => string> = {
  'shifts|INSERT':                     (n) => `maakte ${n} diensten aan`,
  'shifts|DELETE':                     (n) => `verwijderde ${n} diensten`,
  'shifts|status:planned':             (n) => `bevestigde ${n} diensten`,
  'shifts|status:draft':               (n) => `zette ${n} diensten terug naar concept`,
  'shifts|sick:true':                  (n) => `meldde ziek voor ${n} diensten`,
  'shift_declarations|status:approved': (n) => `keurde ${n} declaraties goed`,
  'shift_declarations|status:disputed': (n) => `betwistte ${n} declaraties`,
  'extra_work|status:released':        (n) => `gaf ${n} meerwerkmeldingen vrij`,
  'holidays|INSERT':                   (n) => `voegde ${n} feestdagen toe`,
};

// Welke regel een gemengde transactie mag aanvoeren. Opslaan van een dienst raakt
// shifts en shift_pharmacies; de dienst is wat de planner deed, de koppelregels
// zijn het gevolg.
const PRIORITY = ['shifts', 'shift_declarations', 'extra_work', 'employees', 'user_profiles', 'pharmacies'];

export function groupSentence(g: AuditGroup): string {
  if (g.rows.length === 1 && g.total <= 1) return rowSentence(g.rows[0]);

  const keys = new Set(g.rows.map(verbKey));
  if (keys.size === 1) {
    const key = [...keys][0];
    const plural = PLURAL[key];
    if (plural) return plural(g.total);
    const [table, act] = key.split('|');
    const verb = act === 'INSERT' ? 'maakte' : act === 'DELETE' ? 'verwijderde' : 'wijzigde';
    return `${verb} ${g.total} ${noun(table, true)}${act === 'INSERT' ? ' aan' : ''}`;
  }

  const lead = [...g.rows].sort((a, b) => {
    const pa = PRIORITY.indexOf(a.table_name), pb = PRIORITY.indexOf(b.table_name);
    return (pa < 0 ? 99 : pa) - (pb < 0 ? 99 : pb);
  })[0];
  const others = g.total - 1;
  return `${rowSentence(lead)}${others > 0 ? ` en ${others} ${others === 1 ? 'andere wijziging' : 'andere wijzigingen'}` : ''}`;
}
