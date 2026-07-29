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
