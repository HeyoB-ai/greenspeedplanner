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
    .select('id, name, city, billing_email, groupId')
    .order('name', { ascending: true });
  if (error) throw error;
  return (data ?? []).map((r: any): Pharmacy => ({
    id: r.id,
    name: r.name,
    city: r.city ?? null,
    billingEmail: r.billing_email ?? null,
    groupId: r.groupId ?? null,
  }));
}

// Plaats van een apotheek zetten of wissen (migratie 024). Loopt via een
// SECURITY DEFINER-functie: pharmacies is een gedeelde productietabel en krijgt
// geen schrijfrechten voor de planner, want die zouden meteen voor élke kolom
// gelden. Leeg opslaan wist het veld.
// Adres voor meerwerkmeldingen (migratie 031). Zelfde weg als de plaatsnaam:
// pharmacies krijgt geen schrijfrechten, want die zouden voor élke kolom gelden.
export async function setPharmacyBillingEmail(
  pharmacyId: string, email: string | null,
): Promise<void> {
  const sb = requireClient();
  const { error } = await sb.rpc('set_pharmacy_billing_email', {
    p_pharmacy_id: pharmacyId, p_email: email,
  });
  if (error) throw error;
}

export async function setPharmacyCity(pharmacyId: string, city: string | null): Promise<void> {
  const sb = requireClient();
  const { error } = await sb.rpc('set_pharmacy_city', {
    p_pharmacy_id: pharmacyId, p_city: city,
  });
  if (error) throw error;
}

// Alle koeriers, met hun apotheek-koppelingen uit courier_pharmacy_access (CPA)
// — de echte koppelbron. Sinds migratie 008 mag een planner (is_privileged) de
// volledige CPA lezen; we leunen niet langer op user_profiles.pharmacy_ids (die
// spiegel loopt uiteen: append-only + handmatig bewerkbaar).
export async function getCouriers(): Promise<Courier[]> {
  const sb = requireClient();
  const [{ data: profiles, error: pErr }, { data: cpa, error: cErr }] = await Promise.all([
    sb.from('user_profiles').select('id, name').eq('role', 'courier').order('name', { ascending: true }),
    sb.from('courier_pharmacy_access').select('courier_id, pharmacy_id'),
  ]);
  if (pErr) throw pErr;
  if (cErr) throw cErr;

  const byCourier = new Map<string, string[]>();
  (cpa ?? []).forEach((r: any) => {
    const list = byCourier.get(r.courier_id) ?? [];
    list.push(r.pharmacy_id);
    byCourier.set(r.courier_id, list);
  });

  return (profiles ?? []).map((r: any) => ({
    id: r.id,
    name: r.name,
    pharmacyIds: byCourier.get(r.id) ?? [],
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
    .select('id, courier_id, shift_type, shift_date, start_time, budgeted_end_time, status, transport_mode, car_is_own, description, timing_reliable, schedule_id, urgent_amount, urgent_note')
    .gte('shift_date', startDate)
    .lte('shift_date', endDate)
    .order('start_time', { ascending: true });
  if (error) throw error;

  const rows = shifts ?? [];
  if (rows.length === 0) return [];
  const ids = rows.map((s: any) => s.id);

  const [{ data: sp }, { data: si }, couriers] = await Promise.all([
    sb.from('shift_pharmacies').select('shift_id, pharmacy_id, budgeted_minutes').in('shift_id', ids),
    sb.from('shift_institutions').select('shift_id, institution_id').in('shift_id', ids),
    getCouriers(),
  ]);

  const courierName = new Map(couriers.map((c) => [c.id, c.name]));
  const pharmaciesByShift = new Map<string, string[]>();
  // Geplande minuten per (dienst, apotheek). Los van de id-lijst omdat de rest
  // van de app alleen de ids nodig heeft.
  const minutesByShift = new Map<string, Record<string, number | null>>();
  (sp ?? []).forEach((r: any) => {
    const list = pharmaciesByShift.get(r.shift_id) ?? [];
    list.push(r.pharmacy_id);
    pharmaciesByShift.set(r.shift_id, list);
    const mins = minutesByShift.get(r.shift_id) ?? {};
    mins[r.pharmacy_id] = r.budgeted_minutes ?? null;
    minutesByShift.set(r.shift_id, mins);
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
    carIsOwn: s.car_is_own ?? null,
    description: s.description,
    pharmacyIds: pharmaciesByShift.get(s.id) ?? [],
    pharmacyMinutes: minutesByShift.get(s.id) ?? {},
    urgentAmount: s.urgent_amount != null ? Number(s.urgent_amount) : null,
    urgentNote: s.urgent_note ?? null,
    institutionIds: institutionsByShift.get(s.id) ?? [],
    timingReliable: s.timing_reliable ?? false,
    scheduleId: s.schedule_id ?? null,
  }));
}

// Diensten van één koerier op één datum — voor de conflictcheck bij opslaan.
export async function getCourierShiftsOnDate(
  courierId: string, dateISO: string, excludeShiftId?: string,
): Promise<Shift[]> {
  const sb = requireClient();
  let q = sb
    .from('shifts')
    .select('id, courier_id, shift_type, shift_date, start_time, budgeted_end_time, status, transport_mode, car_is_own, description, timing_reliable, schedule_id')
    .eq('courier_id', courierId)
    .eq('shift_date', dateISO);
  if (excludeShiftId) q = q.neq('id', excludeShiftId);
  const { data: rows, error } = await q;
  if (error) throw error;
  const list = rows ?? [];
  if (list.length === 0) return [];

  const ids = list.map((s: any) => s.id);
  const { data: sp } = await sb.from('shift_pharmacies').select('shift_id, pharmacy_id').in('shift_id', ids);
  const byShift = new Map<string, string[]>();
  (sp ?? []).forEach((r: any) => {
    const l = byShift.get(r.shift_id) ?? [];
    l.push(r.pharmacy_id);
    byShift.set(r.shift_id, l);
  });

  return list.map((s: any): Shift => ({
    id: s.id,
    courierId: s.courier_id,
    courierName: null,
    shiftType: s.shift_type,
    shiftDate: s.shift_date,
    startTime: shortTime(s.start_time),
    budgetedEndTime: s.budgeted_end_time ? shortTime(s.budgeted_end_time) : null,
    status: s.status,
    transportMode: s.transport_mode,
    carIsOwn: s.car_is_own ?? null,
    description: s.description,
    pharmacyIds: byShift.get(s.id) ?? [],
    // Deze lijst dient alleen de conflictdetectie; die kijkt naar tijden, niet
    // naar minuten of bedragen. Vandaar leeg in plaats van een extra query.
    pharmacyMinutes: {},
    urgentAmount: null,
    urgentNote: null,
    institutionIds: [],
    timingReliable: s.timing_reliable ?? false,
    scheduleId: s.schedule_id ?? null,
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
      // Bij fiets altijd null; bij auto mag null (= nog niet bekend) sinds 013.
      car_is_own: input.transportMode === 'car' ? input.carIsOwn : null,
      // status niet meegegeven → DB-default 'draft' (concept). Bevestigen tilt
      // hem later naar 'planned'.
      description: input.description,
      timing_reliable: input.timingReliable,
      // Alleen bij spoed; de trigger uit migratie 025 weigert ze bij een ander
      // type, dus expliciet null meesturen in plaats van laten hangen.
      urgent_amount: input.shiftType === 'urgent' ? input.urgentAmount : null,
      urgent_note: input.shiftType === 'urgent' ? input.urgentNote : null,
      created_by: session?.user.id ?? null,
    })
    .select('id')
    .single();
  if (error) throw error;

  const shiftId = shift.id as string;

  if (input.pharmacyIds.length > 0) {
    const { error: spErr } = await sb
      .from('shift_pharmacies')
      .insert(input.pharmacyIds.map((pid) => ({
        shift_id: shiftId,
        pharmacy_id: pid,
        budgeted_minutes: input.pharmacyMinutes[pid] ?? null,
      })));
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
// op via ON DELETE CASCADE (zie migratie 001). Kwam de dienst uit een rooster,
// dan legt de DB-trigger (migratie 010) de datum vast als exception, zodat de
// generator hem niet opnieuw aanmaakt. Systeem-opschoning gebruikt daarentegen
// remove_future_schedule_drafts (suppressievlag) en laat géén exception achter.
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
      // Altijd meeschrijven, ook bij fiets. Zou car_is_own hier ongemoeid
      // blijven, dan overleeft een eerdere autokeuze de omschakeling naar fiets
      // en duikt hij weer op zodra iemand terugzet naar auto — een waarde die
      // niemand op dat moment gekozen heeft.
      car_is_own: input.transportMode === 'car' ? input.carIsOwn : null,
      description: input.description,
      timing_reliable: input.timingReliable,
      // Altijd meeschrijven, net als car_is_own: zou dit bij een typewissel
      // blijven staan, dan hangt er een spoedbedrag aan een reguliere dienst en
      // weigert de trigger uit migratie 025 de hele update.
      urgent_amount: input.shiftType === 'urgent' ? input.urgentAmount : null,
      urgent_note: input.shiftType === 'urgent' ? input.urgentNote : null,
    })
    .eq('id', shiftId);
  if (error) throw error;

  // shift_pharmacies synchroniseren, inclusief de geplande minuten. Kan niet via
  // syncJunction: die kijkt alleen naar wélke koppelingen er zijn, en dan zou een
  // gewijzigd aantal minuten op een blijvende koppeling niet worden opgeslagen.
  await syncPharmacies(shiftId, input.pharmacyIds, input.pharmacyMinutes);

  // shift_institutions synchroniseren. Bij een niet-instelling-dienst mogen er
  // géén instelling-koppelingen overblijven.
  const wantedInstitutions = input.shiftType === 'institution' ? input.institutionIds : [];
  await syncJunction(
    'shift_institutions', 'institution_id', shiftId, wantedInstitutions,
  );
}

// Apotheken van een dienst bijwerken: weghalen wat weg moet, en de rest in één
// upsert neerzetten. De upsert dekt twee gevallen tegelijk — een nieuwe apotheek
// erbij, en een gewijzigd aantal minuten op een apotheek die er al aan hing.
async function syncPharmacies(
  shiftId: string,
  wantedIds: string[],
  minutes: Record<string, number | null>,
): Promise<void> {
  const sb = requireClient();

  const { data: current, error: readErr } = await sb
    .from('shift_pharmacies')
    .select('pharmacy_id')
    .eq('shift_id', shiftId);
  if (readErr) throw readErr;

  const wanted = new Set(wantedIds);
  const toRemove = (current ?? [])
    .map((r: any) => r.pharmacy_id as string)
    .filter((id) => !wanted.has(id));

  if (toRemove.length > 0) {
    const { error: delErr } = await sb
      .from('shift_pharmacies')
      .delete()
      .eq('shift_id', shiftId)
      .in('pharmacy_id', toRemove);
    if (delErr) throw delErr;
  }

  if (wantedIds.length > 0) {
    const { error: upErr } = await sb
      .from('shift_pharmacies')
      .upsert(
        wantedIds.map((pid) => ({
          shift_id: shiftId,
          pharmacy_id: pid,
          budgeted_minutes: minutes[pid] ?? null,
        })),
        { onConflict: 'shift_id,pharmacy_id' },
      );
    if (upErr) throw upErr;
  }
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
