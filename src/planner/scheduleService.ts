import { supabase } from '../lib/supabase';
import { ScheduleLine, ScheduleLineInput } from '../types';
import { addDays, toISODate } from './dates';

const HORIZON_WEEKS = 10;

function requireClient() {
  if (!supabase) throw new Error('Supabase is niet geconfigureerd.');
  return supabase;
}

function toLine(r: any): ScheduleLine {
  return {
    id: r.id,
    pharmacyId: r.pharmacy_id,
    weekday: r.weekday,
    startTime: (r.start_time ?? '').slice(0, 5),
    budgetedEndTime: r.budgeted_end_time ? r.budgeted_end_time.slice(0, 5) : null,
    courierId: r.courier_id,
    transportMode: r.transport_mode,
    carIsOwn: r.car_is_own,
    startDate: r.start_date,
    endDate: r.end_date,
    isActive: r.is_active,
  };
}

function toRow(input: ScheduleLineInput) {
  return {
    pharmacy_id: input.pharmacyId,
    weekday: input.weekday,
    start_time: input.startTime,
    budgeted_end_time: input.budgetedEndTime,
    courier_id: input.courierId,
    transport_mode: input.transportMode,
    car_is_own: input.carIsOwn,
    start_date: input.startDate,
    end_date: input.endDate,
  };
}

// Alle roosterregels van een apotheek (actief + inactief), voor het beheer.
export async function getSchedules(pharmacyId: string): Promise<ScheduleLine[]> {
  const sb = requireClient();
  const { data, error } = await sb
    .from('pharmacy_schedules')
    .select('*')
    .eq('pharmacy_id', pharmacyId)
    .order('is_active', { ascending: false })
    .order('weekday', { ascending: true })
    .order('start_time', { ascending: true });
  if (error) throw error;
  return (data ?? []).map(toLine);
}

export async function createSchedule(input: ScheduleLineInput): Promise<void> {
  const sb = requireClient();
  const { data: { session } } = await sb.auth.getSession();
  const { error } = await sb
    .from('pharmacy_schedules')
    .insert({ ...toRow(input), created_by: session?.user.id ?? null });
  if (error) throw error;
  await generateScheduleShifts();
}

// Wijzigen: regel bijwerken, dan de TOEKOMSTIGE concepten van deze regel
// weggooien en opnieuw genereren. Uniform voor elk soort wijziging (tijd,
// koerier, vervoermiddel, weekdag, datums); bevestigde diensten blijven staan
// (filter status='draft'), en bestaande exceptions blijven behouden (ze hangen
// aan schedule_id, niet aan de dienst). Deze opschoning legt GEEN exceptions vast.
export async function updateSchedule(id: string, input: ScheduleLineInput): Promise<void> {
  const sb = requireClient();
  const { error } = await sb.from('pharmacy_schedules').update(toRow(input)).eq('id', id);
  if (error) throw error;
  await removeFutureScheduleDrafts(id);
  await generateScheduleShifts();
}

// Deactiveren i.p.v. verwijderen: bevestigde diensten behouden hun schedule_id
// (herkomst blijft), toekomstige concepten worden opgeruimd. De DB blokkeert een
// harde delete van een regel met diensten (ON DELETE RESTRICT), dus dit is de weg.
export async function deactivateSchedule(id: string): Promise<void> {
  const sb = requireClient();
  const { error } = await sb.from('pharmacy_schedules').update({ is_active: false }).eq('id', id);
  if (error) throw error;
  await removeFutureScheduleDrafts(id);
}

// Systeem-opschoning via de RPC (migratie 010): verwijdert de toekomstige
// concepten van een regel binnen één transactie die zichzelf als opschoning
// markeert, zodat de delete-trigger géén exception vastlegt (i.t.t. de
// handmatige deleteShift). Bewust géén losse client-delete: dan zou het
// markeren en het verwijderen in twee transacties vallen en de markering niets
// meer betekenen.
async function removeFutureScheduleDrafts(scheduleId: string): Promise<void> {
  const sb = requireClient();
  const { error } = await sb.rpc('remove_future_schedule_drafts', { p_schedule_id: scheduleId });
  if (error) throw error;
}

// Roept de generator-RPC aan (idempotent, server-side, atomair). Geeft het
// aantal nieuw aangemaakte concepten terug.
export async function generateScheduleShifts(): Promise<number> {
  const sb = requireClient();
  const { data, error } = await sb.rpc('generate_schedule_shifts', { p_horizon_weeks: HORIZON_WEEKS });
  if (error) throw error;
  return (data as number) ?? 0;
}

// App-open: vul het venster bij als het nog niet t/m het horizon-eind gevuld is.
// De marker (filled_through) staat in de DB, zodat een tweede planner/apparaat
// niet opnieuw hoeft te draaien.
export async function topUpScheduleWindow(): Promise<number> {
  const sb = requireClient();
  const windowEnd = scheduleHorizonEndISO();
  const { data, error } = await sb
    .from('schedule_generation_state')
    .select('filled_through')
    .maybeSingle();
  if (error) throw error;
  if (data?.filled_through && data.filled_through >= windowEnd) return 0;
  return generateScheduleShifts();
}

// Einddatum van het meelopende roostervenster (vandaag + horizon).
export function scheduleHorizonEndISO(): string {
  return toISODate(addDays(new Date(), HORIZON_WEEKS * 7));
}

// Laatst bekende feestdag — voor de waarschuwing als de horizon daar voorbij reikt.
export async function getMaxHolidayDate(): Promise<string | null> {
  const sb = requireClient();
  const { data, error } = await sb
    .from('holidays')
    .select('holiday_date')
    .order('holiday_date', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error) throw error;
  return data?.holiday_date ?? null;
}
