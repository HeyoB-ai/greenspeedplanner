-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — eigen/bedrijfsauto mag onbekend blijven — migratie 013
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
--
-- WAAROM DE CONSTRAINT VERVALT
-- Migratie 006 eiste bij transport_mode = 'car' een ingevulde car_is_own, met
-- als reden: geen default false, want dan is "planner is het vergeten" niet te
-- onderscheiden van "bedrijfsauto" en verdwijnen kilometers stilzwijgend.
--
-- In de praktijk blijkt de planner het bij het inplannen vaak nog niet te weten.
-- Een verplichte keuze levert dan geen kennis op maar een gok — en die gok valt
-- in de praktijk altijd op 'bedrijfsauto', precies de stilzwijgende default die
-- 006 wilde voorkomen. Beter een lege waarde die zichtbaar leeg is.
--
-- WAT DE GARANTIE VERVANGT
-- NULL bij een autodienst betekent voortaan "nog niet bekend". Dat is een
-- bewuste keuze in het formulier (derde optie naast eigen/bedrijfsauto), en de
-- planner ziet het terug: het weekoverzicht en de dagweergave markeren een
-- autodienst zonder keuze in amber. De controle verschuift dus van de database
-- naar iets wat de planner kan zien en oplossen.
--
-- BIJVANGST — dit repareert ook een storing die niets met het formulier te maken
-- had: de CHECK van 006 stond NOT VALID, dus bestaande 'car'-rijen zonder keuze
-- werden gegrandfatherd. Elke UPDATE op zo'n rij hercontroleerde hem alsnog,
-- waardoor zelfs het bevestigen van een concept (dat transport_mode niet eens
-- aanraakt) faalde op shifts_car_is_own_chk.
--
-- Hoeveel rijen dat betreft, vóór of ná deze migratie op te vragen:
--   SELECT count(*) FROM public.shifts WHERE transport_mode = 'car' AND car_is_own IS NULL;
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- shifts — constraint uit migratie 006.
ALTER TABLE public.shifts
  DROP CONSTRAINT IF EXISTS shifts_car_is_own_chk;

-- pharmacy_schedules — dezelfde regel, inline benoemd in migratie 009.
ALTER TABLE public.pharmacy_schedules
  DROP CONSTRAINT IF EXISTS pharmacy_schedules_car_chk;

-- De kolommen zelf blijven ongemoeid: boolean NULL, waarbij NULL bij een
-- fietsdienst "niet van toepassing" betekent en bij een autodienst "nog niet
-- bekend". Het formulier zet hem expliciet op NULL zodra je naar Fiets schakelt,
-- zodat een eerder gekozen waarde niet blijft hangen.

-- ────────────────────────────────────────────────────────────────────────
-- Verificatie — verwacht: geen van beide constraints meer aanwezig.
-- ────────────────────────────────────────────────────────────────────────
SELECT conrelid::regclass AS tabel, conname
FROM pg_constraint
WHERE conname IN ('shifts_car_is_own_chk', 'pharmacy_schedules_car_chk');

COMMIT;
