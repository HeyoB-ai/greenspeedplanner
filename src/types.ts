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
  institutionIds: string[];
  // Planner-assertie dat de tijden bruikbaar zijn voor kalibratie (default false).
  timingReliable: boolean;
  // Herkomst: gevuld = uit een roosterregel gegenereerd; null = handmatig.
  scheduleId: string | null;
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
  institutionIds: string[];
  timingReliable: boolean;
}

// ── Nadeclaratie (fase 6, migraties 018/019) ──────────────────────────────

// Status van één declaratie. 'open' = de koerier heeft nog niets ingevuld.
export type DeclarationStatus = 'open' | 'submitted' | 'approved' | 'disputed';

// Welke tak van de reiskostenregel gold. Zie migratie 018.
//  own_car         eigen auto: de opgegeven km's, drempel vervalt
//  other_pharmacy  andere apotheek dan de standplaats: volledige afstand
//  above_threshold afstand min drempel
//  none            binnen de drempel: geen vergoeding
export type ReimbursementRule = 'own_car' | 'other_pharmacy' | 'above_threshold' | 'none';

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
  reviewed_at: string | null;
  reviewer_name: string | null;
  review_note: string | null;
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
