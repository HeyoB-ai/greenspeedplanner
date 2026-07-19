// ── Domeintypes voor de planningsmodule ──────────────────────────────────
// Kolomnamen volgen exact het gedeelde Greenspeed-schema (migraties 001/003).

export type ShiftType = 'regular' | 'institution' | 'other_transport' | 'urgent';
export type TransportMode = 'bike' | 'car';
// status: nu functioneel enkel 'planned'; de rest is ruimte voor het latere
// biedmodel (niet gebouwd). We laten het veld intact.
export type ShiftStatus = 'planned' | 'offered' | 'claimed' | 'assigned';

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
  description: string | null;
  pharmacyIds: string[];
  institutionIds: string[];
}

// Payload voor het aanmaken van een dienst (stap C).
export interface NewShiftInput {
  courierId: string | null;
  shiftType: ShiftType;
  shiftDate: string;              // 'YYYY-MM-DD'
  startTime: string;              // 'HH:MM'
  budgetedEndTime: string | null; // 'HH:MM'
  transportMode: TransportMode;
  description: string | null;
  pharmacyIds: string[];
  institutionIds: string[];
}
