-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — kalibratie-markering op shifts — migratie 007
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Staat volledig los van 006 (die raakt shift_time_reports; deze alleen shifts).
--
-- Testritten en echte ritten lopen door elkaar en dat blijft zo — er komt geen
-- datum waarna alles vanzelf betrouwbaar is. Retroactief opschonen kan niet;
-- vooruit labelen wel. Deze vlag legt bij het plannen vast of de TIJDEN van een
-- dienst bruikbaar zijn voor kalibratie: was dit een volledige, echte dienst van
-- ophalen tot laatste bezorging?
--
-- Default FALSE: vervuiling is duurder dan een gemiste dienst, dus niets telt
-- mee tenzij de planner het bewust aanvinkt. Bestaande (test)diensten vallen zo
-- automatisch buiten de kalibratie — geen backfill nodig.
--
-- Technische volledigheid (ontbrekende scans, gaten, tweede rit) blijft het werk
-- van de dispute-detectie in het model; de kalibratie neemt alleen diensten mee
-- die timing_reliable = true ÉN niet disputed zijn.
-- ════════════════════════════════════════════════════════════════════════

ALTER TABLE public.shifts
  ADD COLUMN IF NOT EXISTS timing_reliable BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.shifts.timing_reliable IS
  'Planner-assertie: volledige, echte dienst waarvan de tijden bruikbaar zijn '
  'voor kalibratie. Default false. Kalibratie filtert hierop (én op niet-disputed).';
