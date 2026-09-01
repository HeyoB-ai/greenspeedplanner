// ── Domeintypes voor de planningsmodule ──────────────────────────────────
// Kolomnamen volgen exact het gedeelde Greenspeed-schema (migraties 001/003).

export type ShiftType = 'regular' | 'institution' | 'other_transport' | 'urgent';
export type TransportMode = 'bike' | 'car';
// 'draft'  = concept, alleen voor planners zichtbaar, nog niet bij de koerier.
// 'planned' = bevestigd. offered/claimed/assigned zijn ruimte voor het latere
// biedmodel (niet gebouwd). We laten die waarden intact.
export type ShiftStatus = 'draft' | 'planned' | 'offered' | 'claimed' | 'assigned';

// DB-rollen zijn lowercase (zie user_profiles.role in migratie 001).
export type DbRole = 'superuser' | 'supervisor' | 'admin' | 'pharmacy' | 'courier';

// Rollen die het plannerscherm mogen zien/beheren (spiegelt is_privileged()).
export const PLANNER_ROLES: DbRole[] = ['superuser', 'supervisor', 'admin'];

export interface SessionUser {
  id: string;
  name: string;
  role: DbRole;
}

export interface Pharmacy {
  id: string;   // TEXT, bv. 'ph-1779784742417'
  name: string;
  // Plaatsnaam uit pharmacies.city. Bestond al in het schema van de bezorg-app
  // maar was nergens te vullen; sinds migratie 024 kan dat in het apotheekbeheer.
  // null = onbekend → groepeert in het weekoverzicht onder "Overig".
  city: string | null;
  // Waar meerwerkmeldingen heen gaan (migratie 031). Zonder adres kan een
  // melding niet vrijgegeven worden.
  billingEmail: string | null;
  // De keten waar deze apotheek bij hoort (pharmacies."groupId"). Bepaalt of de
  // factuur gesplitst wordt (migratie 032).
  groupId: string | null;
}

// Eén keten met zijn facturatie-instelling (migratie 032).
export interface Chain {
  group_id: string;
  group_name: string;
  billing_email: string | null;
  split_extra_work: boolean;
  pharmacies: number;
}

export interface Institution {
  id: string;         // TEXT
  name: string;
  pharmacyId: string; // kolom "pharmacyId" in institutions
}

export interface Courier {
  id: string;
  name: string;
  pharmacyIds: string[]; // user_profiles.pharmacy_ids
}

// Rij uit shifts, verrijkt met de gekoppelde apotheek-/instelling-ids en
// de koeriersnaam (in JS samengevoegd uit de koppeltabellen).
export interface Shift {
  id: string;
  courierId: string | null;
  courierName: string | null;
  shiftType: ShiftType;
  shiftDate: string;             // 'YYYY-MM-DD'
  startTime: string;             // 'HH:MM' (afgekapt van HH:MM:SS)
  budgetedEndTime: string | null;// 'HH:MM' of null
  status: ShiftStatus;
  transportMode: TransportMode;
  // Alleen betekenisvol bij transportMode 'car'. null = nog niet bekend; bij
  // 'bike' altijd null. De DB dwingt sinds migratie 013 niets meer af, dus de
  // waarde moet expliciet meegeschreven worden bij elke wijziging.
  carIsOwn: boolean | null;
  description: string | null;
  pharmacyIds: string[];
  // Geplande minuten per apotheek (shift_pharmacies.budgeted_minutes, migratie
  // 025). Bepaalt de verhouding waarmee de werkelijke duur en de reiskosten over
  // de apotheken verdeeld worden bij het factureren. Ontbreekt een waarde, dan
  // verdeelt invoice_lines() gelijk en markeert de regel.
  pharmacyMinutes: Record<string, number | null>;
  institutionIds: string[];
  // Planner-assertie dat de tijden bruikbaar zijn voor kalibratie (default false).
  timingReliable: boolean;
  // Herkomst: gevuld = uit een roosterregel gegenereerd; null = handmatig.
  scheduleId: string | null;
  // Alleen bij shiftType 'urgent': het telefonisch afgesproken bedrag richting de
  // apotheek, plus een toelichting. Bij spoed is dit het HELE factuurbedrag.
  urgentAmount: number | null;
  urgentNote: string | null;
}

// Eén roosterregel (vaste, terugkerende dienst) voor een apotheek.
export interface ScheduleLine {
  id: string;
  pharmacyId: string;
  weekday: number;               // ISO 1=maandag .. 7=zondag
  startTime: string;             // 'HH:MM'
  budgetedEndTime: string | null;
  courierId: string | null;
  transportMode: TransportMode;
  carIsOwn: boolean | null;
  startDate: string;             // 'YYYY-MM-DD'
  endDate: string | null;
  isActive: boolean;
}

export type ScheduleLineInput = Omit<ScheduleLine, 'id' | 'isActive'>;

// Verstuurstatus van de herinnerings-SMS van één dienst (migratie 012).
// 'sending' = geclaimd maar geen bevestiging van de provider: het proces is
// tussen claimen en versturen gestorven. Er gaat dan géén bericht meer uit.
export type SmsStatus = 'sending' | 'sent' | 'failed';

export interface SmsLogEntry {
  shiftId: string;
  status: SmsStatus;
  sentAt: string | null;
  error: string | null;
  phoneE164: string;
}

// Telefoonnummer van een koerier (migratie 011). Staat bewust NIET op
// user_profiles: die tabel is van de bezorg-app en heeft een zelf-leespad.
export interface CourierContact {
  courierId: string;
  phoneE164: string;   // altijd E.164, bv. '+31612345678'
  note: string | null;
  updatedAt: string;
}

// Payload voor het aanmaken van een dienst (stap C).
export interface NewShiftInput {
  courierId: string | null;
  shiftType: ShiftType;
  shiftDate: string;              // 'YYYY-MM-DD'
  startTime: string;              // 'HH:MM'
  budgetedEndTime: string | null; // 'HH:MM'
  transportMode: TransportMode;
  carIsOwn: boolean | null;       // null = nog niet bekend (of fiets)
  description: string | null;
  pharmacyIds: string[];
  pharmacyMinutes: Record<string, number | null>;
  institutionIds: string[];
  timingReliable: boolean;
  urgentAmount: number | null;
  urgentNote: string | null;
}

// ── Facturatie (fase 7, migratie 025) ─────────────────────────────────────

// Tarief van één apotheek vanaf een ingangsdatum. Een tariefwijziging is een
// nieuwe rij, nooit een wijziging van een bestaande: oude facturen verwijzen
// naar het tarief dat toen gold.
export interface PharmacyRate {
  id: string;
  pharmacyId: string;
  // Vier uurtarieven sinds migratie 030: wat het werk kost hangt af van wát het
  // is. null = geen tarief voor dat soort werk; een dienst van die soort levert
  // dan een onvolledige factuurregel op in plaats van een nul.
  hourlyRateBike: number | null;
  hourlyRateCar: number | null;
  hourlyRateInstitution: number | null;
  hourlyRateOther: number | null;
  startRate: number;
  effectiveFrom: string;   // 'YYYY-MM-DD'
  note: string | null;
}

// ── Meerwerk (fase 9, migratie 031) ───────────────────────────────────────

export type ExtraWorkStatus = 'new' | 'released' | 'approved' | 'disputed' | 'expired';

// Eén meerwerkmelding, per dienst per apotheek. De planner ziet hem eerst en
// geeft hem vrij; pas dan gaat er post naar de klant.
export interface ExtraWorkRow {
  extra_work_id: string;
  shift_id: string;
  shift_date: string;
  pharmacy_id: string;
  pharmacy_name: string;
  billing_email: string | null;
  courier_name: string | null;
  planned_minutes: number;
  actual_minutes: number;
  extra_minutes: number;
  share_pct: number;
  share_minutes: number;
  courier_note: string | null;
  planner_note: string | null;
  status: ExtraWorkStatus;
  released_at: string | null;
  sent_at: string | null;
  respond_by: string | null;
  responded_at: string | null;
  response_note: string | null;
}

// Eén regel uit invoice_lines(). Namen volgen de functie 1-op-1 (snake_case),
// zodat er geen tweede woordenlijst te onderhouden valt.
export interface InvoiceLine {
  shift_id: string;
  shift_date: string;
  shift_type: ShiftType;
  courier_name: string | null;
  pharmacies_in_shift: number;
  planned_minutes: number | null;
  share_pct: number;
  shift_planned_minutes: number | null;
  shift_actual_minutes: number | null;
  // Kan null zijn: zonder werkelijke duur én zonder geplande eindtijd is er
  // niets te factureren, en dan is het bedrag onbekend — niet nul (migratie 026).
  billed_minutes: number | null;
  from_declaration: boolean;
  hourly_rate: number | null;
  rate_id: string | null;
  hours_amount: number | null;
  start_amount: number | null;
  travel_amount: number | null;
  // Doorbelaste onkosten, naar rato van de geplande minuten en zonder marge.
  expenses_amount: number | null;
  // Meerwerk (migratie 031). approved en expired leveren allebei een regel op,
  // maar bij expired heeft nooit iemand gekeken — dat moet zichtbaar blijven.
  extra_work_status: ExtraWorkStatus | null;
  extra_work_minutes: number | null;
  // Verdeling over keten en filiaal (migratie 032). Staat de splitsing uit, dan
  // is chain_amount 0 en branch_amount het hele bedrag. Samen altijd line_total.
  chain_id: string | null;
  chain_name: string | null;
  split_active: boolean;
  chain_amount: number | null;
  branch_amount: number | null;
  urgent_amount: number | null;
  urgent_note: string | null;
  line_total: number | null;
  incomplete: boolean;
  reason: string | null;
}

// ── Nadeclaratie (fase 6, migraties 018/019) ──────────────────────────────

// Status van één declaratie. 'open' = de koerier heeft nog niets ingevuld.
export type DeclarationStatus = 'open' | 'submitted' | 'approved' | 'disputed';

// Welke tak van de reiskostenregel gold. Zie migratie 018.
//  own_car         eigen auto: de opgegeven km's, drempel vervalt
//  other_pharmacy  andere apotheek dan de standplaats: volledige afstand
//  above_threshold afstand min drempel
//  none            binnen de drempel: geen vergoeding
// 'zzp' (migratie 035): geen recht op kilometervergoeding — de zzp'er
// declareert zijn kilometers als onkostenpost, net als parkeren.
export type ReimbursementRule = 'own_car' | 'other_pharmacy' | 'above_threshold' | 'none' | 'zzp';

// Eén rij uit declaration_overview(): wat de koerier opgaf naast wat het
// systeem berekende. De namen volgen de functie 1-op-1 (snake_case), zodat de
// tussenlaag geen twee woordenlijsten hoeft te onderhouden.
export interface DeclarationRow {
  declaration_id: string;
  shift_id: string;
  status: DeclarationStatus;
  courier_id: string;
  courier_name: string;
  shift_date: string;
  pharmacies: string[];
  transport_mode: TransportMode;
  own_car: boolean;
  planned_start: string | null;
  planned_end: string | null;
  planned_minutes: number | null;
  actual_start: string | null;
  actual_end: string | null;
  actual_minutes: number | null;
  claims_travel: boolean | null;
  own_car_km: number | null;
  courier_note: string | null;
  computed_distance_km: number | null;
  computed_reimbursable_km: number | null;
  computed_rule: ReimbursementRule | null;
  computed_pharmacy_name: string | null;
  computed_incomplete: boolean;
  computed_reason: string | null;
  rate_per_km: number | null;
  threshold_km: number | null;
  amount_eur: number | null;
  submitted_at: string | null;
  // Tijdigheid, afgeleid (migratie 021) — geen kolom en geen status.
  // hours_after_end:   ingediend → uren tussen de eindtijd en het indienen;
  //                    nog niet  → uren dat de rij al openstaat.
  // submitted_in_time: NULL zolang er niets is ingediend. Niet ingediend is
  //                    niet te laat; het is niet ingediend.
  hours_after_end: number | null;
  submitted_in_time: boolean | null;
  expected_within_hours: number;
  // Onkosten die geen kilometervergoeding zijn (migratie 028): parkeren, een
  // veerpont, een OV-kaartje. expects_receipt is een herinnering dat er nog een
  // bon per mail moet komen — een signaal, geen blokkade.
  expenses: DeclarationExpense[];
  expenses_amount: number;
  expects_receipt: boolean;
  reviewed_at: string | null;
  reviewer_name: string | null;
  review_note: string | null;
}

// Eén opgegeven onkostenpost. Het bonnetje zit niet in het systeem: dat gaat
// per mail naar de planning.
export interface DeclarationExpense {
  description: string;
  amount_eur: number;
}

// Standplaats en afstandsdekking per koerier (courier_home_overview()).
export interface CourierHome {
  courierId: string;
  courierName: string;
  homePharmacyId: string | null;
  distances: number;              // aantal apotheken met een bekende afstand
  computedAt: string | null;
}

// Eén afstand uit courier_distances. Het woonadres staat er bewust niet bij:
// dat wordt nergens bewaard.
export interface CourierDistance {
  courierId: string;
  pharmacyId: string;
  distanceKm: number;
  source: 'route' | 'fallback' | 'manual';
  computedAt: string;
}

// ── Personeelsadministratie (fase 8, migratie 029) ────────────────────────

export type EmploymentType = 'loondienst' | 'zzp';

// Eén medewerker. Los van user_profiles: iemand kan hier staan zonder ooit in te
// loggen, en een verwijderd inlogaccount haalt deze rij niet weg.
export interface Employee {
  id: string;
  personnelNumber: string | null;   // zeven van de 69 hebben er geen
  firstName: string;
  lastName: string;
  email: string | null;
  phone: string | null;
  employmentType: EmploymentType | null;
  hourlyWage: number | null;
  wageStartDate: string | null;
  homePharmacyId: string | null;
  employedFrom: string;             // 'YYYY-MM-DD'
  employedUntil: string | null;     // null = nog in dienst
  userProfileId: string | null;     // gevuld zodra iemand kan inloggen
  note: string | null;
  isActive: boolean;                // uit employees_active; datum, geen vinkje
}

// Wat de import per rij terugmeldt, zodat het scherm een verslag kan tonen in
// plaats van "69 verwerkt".
export interface EmployeeImportResult {
  row_number: number;
  personnel_number: string | null;
  full_name: string;
  action: 'nieuw' | 'bijgewerkt' | 'overgeslagen';
  note: string | null;
}
