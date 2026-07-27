-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — apotheekcoördinaten — migratie 004
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
--
-- De terugreis van de laatste deurscan naar de apotheek (in het rekenmodel voor
-- de diensttijd) heeft de apotheeklocatie nodig. Apotheken hadden nog geen
-- coördinaten; institutions wel ("addressLat"/"addressLng", double precision).
-- We volgen exact die naamgeving en typen.
--
-- Additief en niet-brekend: nullable kolommen, verder niets aan deze gedeelde
-- productietabel aanraken. De kolommen worden gevuld door het eenmalige,
-- idempotente backfill-script (scripts/backfill-pharmacy-coords.mjs).
-- ════════════════════════════════════════════════════════════════════════

ALTER TABLE public.pharmacies
  ADD COLUMN IF NOT EXISTS "addressLat" DOUBLE PRECISION,
  ADD COLUMN IF NOT EXISTS "addressLng" DOUBLE PRECISION;
