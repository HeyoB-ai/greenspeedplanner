-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — transport_mode op shifts — migratie 003
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de bestaande Greenspeed-database
-- (dezelfde DB waarop 001_shift_planning.sql draaide).
--
-- Voegt het vervoermiddel toe aan een dienst. Zelfde patroon als shift_type:
-- TEXT + inline CHECK (geen Postgres enum). Later uitbreiden (scooter,
-- bakfiets) = de CHECK-constraint droppen en opnieuw zetten met extra waarden.
-- Bestaande rijen krijgen de DEFAULT 'bike'.
-- ════════════════════════════════════════════════════════════════════════

ALTER TABLE public.shifts
  ADD COLUMN IF NOT EXISTS transport_mode TEXT NOT NULL DEFAULT 'bike'
    CHECK (transport_mode IN ('bike', 'car'));
