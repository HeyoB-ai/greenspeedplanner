import { supabase } from '../lib/supabase';
import {
  Courier, Institution, NewShiftInput, Pharmacy, Shift, ShiftType, TransportMode,
} from '../types';
import { shortTime } from './dates';

function requireClient() {
  if (!supabase) throw new Error('Supabase is niet geconfigureerd.');
  return supabase;
}

// ── Referentiedata ────────────────────────────────────────────────────────

export async function getPharmacies(): Promise<Pharmacy[]> {
  const sb = requireClient();
  const { data, error } = await sb
    .from('pharmacies')
    .select('id, name')
    .order('name', { ascending: true });
  if (error) throw error;
  return (data ?? []) as Pharmacy[];
}

// Alle koeriers (planners mogen alle profielen lezen via is_privileged()).
// pharmacy_ids is de planner-leesbare bron voor koppelingen — courier_pharmacy_access
// is per RLS enkel voor de koerier zelf leesbaar.
export async function getCouriers(): Promise<Courier[]> {
  const sb = requireClient();
  const { data, error } = await sb
    .from('user_profiles')
    .select('id, name, pharmacy_ids')
    .eq('role', 'courier')
    .order('name', { ascending: true });
  if (error) throw error;
  return (data ?? []).map((r: any) => ({
    id: r.id,
    name: r.name,
    pharmacyIds: (r.pharmacy_ids ?? []) as string[],
  }));
}

// Actieve instellingen van een set apotheken (voor de conditionele multi-select
// bij type 'instelling'). Kolom "pharmacyId" is camelCase in het schema.
export async function getInstitutions(pharmacyIds: string[]): Promise<Institution[]> {
  const sb = requireClient();
  if (pharmacyIds.length === 0) return [];
  const { data, error } = await sb
    .from('institutions')
    .select('id, name, pharmacyId, isActive')
    .in('pharmacyId', pharmacyIds)
    .eq('isActive', true)
    .order('name', { ascending: true });
  if (error) throw error;
  return (data ?? []).map((r: any) => ({
    id: r.id,
    name: r.name,
    pharmacyId: r.pharmacyId,
  }));
}

// ── Diensten van een week ──────────────────────────────────────────────────
// Aparte query's + JS-join i.p.v. PostgREST-embedding: transparanter en robuust
// t.o.v. de dubbele FK (courier_id én created_by) naar user_profiles.
export async function getShiftsForWeek(
  startDate: string,
  endDate: string,
): Promise<Shift[]> {
  const sb = requireClient();

  const { data: shifts, error } = await sb
    .from('shifts')
    .select('id, courier_id, shift_type, shift_date, start_time, budgeted_end_time, status, transport_mode, description')
    .gte('shift_date', startDate)
    .lte('shift_date', endDate)
    .order('start_time', { ascending: true });
  if (error) throw error;

  const rows = shifts ?? [];
  if (rows.length === 0) return [];
  const ids = rows.map((s: any) => s.id);

  const [{ data: sp }, { data: si }, couriers] = await Promise.all([
    sb.from('shift_pharmacies').select('shift_id, pharmacy_id').in('shift_id', ids),
    sb.from('shift_institutions').select('shift_id, institution_id').in('shift_id', ids),
    getCouriers(),
  ]);

  const courierName = new Map(couriers.map((c) => [c.id, c.name]));
  const pharmaciesByShift = new Map<string, string[]>();
  (sp ?? []).forEach((r: any) => {
    const list = pharmaciesByShift.get(r.shift_id) ?? [];
    list.push(r.pharmacy_id);
    pharmaciesByShift.set(r.shift_id, list);
  });
  const institutionsByShift = new Map<string, string[]>();
  (si ?? []).forEach((r: any) => {
    const list = institutionsByShift.get(r.shift_id) ?? [];
    list.push(r.institution_id);
    institutionsByShift.set(r.shift_id, list);
  });

  return rows.map((s: any): Shift => ({
    id: s.id,
    courierId: s.courier_id,
    courierName: s.courier_id ? courierName.get(s.courier_id) ?? null : null,
    shiftType: s.shift_type as ShiftType,
    shiftDate: s.shift_date,
    startTime: shortTime(s.start_time),
    budgetedEndTime: s.budgeted_end_time ? shortTime(s.budgeted_end_time) : null,
    status: s.status,
    transportMode: s.transport_mode as TransportMode,
    description: s.description,
    pharmacyIds: pharmaciesByShift.get(s.id) ?? [],
    institutionIds: institutionsByShift.get(s.id) ?? [],
  }));
}

// ── Aanmaken (stap C) ──────────────────────────────────────────────────────
export async function createShift(input: NewShiftInput): Promise<string> {
  const sb = requireClient();
  const { data: { session } } = await sb.auth.getSession();

  const { data: shift, error } = await sb
    .from('shifts')
    .insert({
      courier_id: input.courierId,
      shift_type: input.shiftType,
      shift_date: input.shiftDate,
      start_time: input.startTime,
      budgeted_end_time: input.budgetedEndTime,
      transport_mode: input.transportMode,
      // status niet meegegeven → DB-default 'draft' (concept). Bevestigen tilt
      // hem later naar 'planned'.
      description: input.description,
      created_by: session?.user.id ?? null,
    })
    .select('id')
    .single();
  if (error) throw error;

  const shiftId = shift.id as string;

  if (input.pharmacyIds.length > 0) {
    const { error: spErr } = await sb
      .from('shift_pharmacies')
      .insert(input.pharmacyIds.map((pid) => ({ shift_id: shiftId, pharmacy_id: pid })));
    if (spErr) throw spErr;
  }

  if (input.shiftType === 'institution' && input.institutionIds.length > 0) {
    const { error: siErr } = await sb
      .from('shift_institutions')
      .insert(input.institutionIds.map((iid) => ({ shift_id: shiftId, institution_id: iid })));
    if (siErr) throw siErr;
  }

  return shiftId;
}

// ── Verwijderen (stap: planners) ────────────────────────────────────────────
// Eén delete op shifts; shift_pharmacies en shift_institutions ruimen zichzelf
// op via ON DELETE CASCADE (zie migratie 001).
export async function deleteShift(shiftId: string): Promise<void> {
  const sb = requireClient();
  const { error } = await sb.from('shifts').delete().eq('id', shiftId);
  if (error) throw error;
}

// ── Wijzigen ────────────────────────────────────────────────────────────────
// Werkt de dienst bij en synchroniseert de koppeltabellen incrementeel
// (verwijder wat weg moet, voeg toe wat nieuw is) i.p.v. delete-all-then-insert,
// om een leeg venster en onnodige churn te voorkomen. status en created_by
// worden bewust niet aangeraakt.
export async function updateShift(shiftId: string, input: NewShiftInput): Promise<void> {
  const sb = requireClient();

  if (input.pharmacyIds.length === 0) {
    throw new Error('Een dienst moet aan minstens één apotheek gekoppeld zijn.');
  }

  const { error } = await sb
    .from('shifts')
    .update({
      courier_id: input.courierId,
      shift_type: input.shiftType,
      shift_date: input.shiftDate,
      start_time: input.startTime,
      budgeted_end_time: input.budgetedEndTime,
      transport_mode: input.transportMode,
      description: input.description,
    })
    .eq('id', shiftId);
  if (error) throw error;

  // shift_pharmacies synchroniseren.
  await syncJunction(
    'shift_pharmacies', 'pharmacy_id', shiftId, input.pharmacyIds,
  );

  // shift_institutions synchroniseren. Bij een niet-instelling-dienst mogen er
  // géén instelling-koppelingen overblijven.
  const wantedInstitutions = input.shiftType === 'institution' ? input.institutionIds : [];
  await syncJunction(
    'shift_institutions', 'institution_id', shiftId, wantedInstitutions,
  );
}

// Verschil bepalen tussen huidige en gewenste koppelingen en alleen dat muteren.
async function syncJunction(
  table: 'shift_pharmacies' | 'shift_institutions',
  column: 'pharmacy_id' | 'institution_id',
  shiftId: string,
  wantedIds: string[],
): Promise<void> {
  const sb = requireClient();

  const { data: current, error: readErr } = await sb
    .from(table)
    .select(column)
    .eq('shift_id', shiftId);
  if (readErr) throw readErr;

  const currentIds = new Set((current ?? []).map((r: any) => r[column] as string));
  const wanted = new Set(wantedIds);

  const toAdd = wantedIds.filter((id) => !currentIds.has(id));
  const toRemove = [...currentIds].filter((id) => !wanted.has(id));

  if (toRemove.length > 0) {
    const { error: delErr } = await sb
      .from(table)
      .delete()
      .eq('shift_id', shiftId)
      .in(column, toRemove);
    if (delErr) throw delErr;
  }

  if (toAdd.length > 0) {
    const { error: insErr } = await sb
      .from(table)
      .insert(toAdd.map((id) => ({ shift_id: shiftId, [column]: id })));
    if (insErr) throw insErr;
  }
}

// ── Concept bevestigen ──────────────────────────────────────────────────────
// 'draft' → 'planned' + wie/wanneer. Alleen rijen die nog concept zijn worden
// geraakt (via .eq('status','draft')), zodat een dubbele klik of een al
// bevestigde dienst niets kapotmaakt. Werkt voor één of meerdere diensten.
export async function confirmShifts(shiftIds: string[]): Promise<void> {
  const sb = requireClient();
  if (shiftIds.length === 0) return;
  const { data: { session } } = await sb.auth.getSession();
  const { error } = await sb
    .from('shifts')
    .update({
      status: 'planned',
      confirmed_at: new Date().toISOString(),
      confirmed_by: session?.user.id ?? null,
    })
    .in('id', shiftIds)
    .eq('status', 'draft');
  if (error) throw error;
}
