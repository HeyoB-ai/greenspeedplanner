-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 030: uurtarief per soort werk
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 030 eerst (of proefdraai 030 met ROLLBACK en daarna dit).
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: één transactie die op ROLLBACK eindigt. Geval 6 haalt
-- onderweg de CHECK op shifts.transport_mode weg om een onbekend vervoermiddel
-- te kunnen zetten; die komt met de rollback gewoon terug.
--
-- OPSTELLING — apotheek A: fiets € 30, auto € 45, instelling € 55, overig € 40,
-- starttarief € 10. Alle diensten duren precies één uur, zodat het uurtarief
-- rechtstreeks in het bedrag terug te zien is.
--
-- WAT DE TEST DEKT
--   1. regular + fiets           → fietstarief
--   2. regular + auto            → autotarief
--   3. institution               → instellingstarief
--   4. other_transport           → tarief voor klussen
--   5. spoed                     → alleen het vrije bedrag, ongewijzigd
--   6. onbekend vervoermiddel    → geen bedrag, leesbare reden
--   7. tarief ontbreekt voor dit soort werk → eigen melding
--   8. starttarief 0 (BENU)      → gewoon 0, geen markering
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- Hulpfunctie: één dienst van precies een uur, met een ingevulde declaratie
-- zodat er op de werkelijke duur gefactureerd wordt en de deviatiemelding niet
-- afgaat. Staat binnen deze transactie en verdwijnt dus met de ROLLBACK.
CREATE OR REPLACE FUNCTION public.test_030_shift(
  p_courier UUID, p_pharmacy TEXT, p_day DATE, p_start TIME,
  p_type TEXT, p_mode TEXT
)
RETURNS UUID
LANGUAGE plpgsql AS $helper$
DECLARE v_shift UUID;
BEGIN
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time,
                             budgeted_end_time, status, transport_mode)
  VALUES (p_courier, p_type, p_day, p_start, p_start + INTERVAL '1 hour',
          'planned', p_mode)
  RETURNING id INTO v_shift;

  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id, budgeted_minutes)
  VALUES (v_shift, p_pharmacy, 60);

  INSERT INTO public.shift_declarations (
    shift_id, courier_id, status, token_hash, token_expires_at,
    actual_start, actual_end, claims_travel)
  VALUES (v_shift, p_courier, 'submitted',
          public.declaration_hash_token('t-030-' || v_shift::TEXT),
          now() + INTERVAL '30 days', p_start, p_start + INTERVAL '1 hour', false);

  RETURN v_shift;
END;
$helper$;

DO $$
DECLARE
  v_planner UUID;
  v_courier UUID;
  v_a       TEXT;
  v_b       TEXT;
  v_day     DATE := current_date - 4;
  v_shift   UUID;
  v_row     RECORD;
BEGIN
  SELECT id INTO v_planner FROM public.user_profiles
   WHERE role IN ('superuser','supervisor','admin') ORDER BY id LIMIT 1;
  IF v_planner IS NULL THEN RAISE EXCEPTION 'OPZET: geen planner in user_profiles.'; END IF;
  SELECT id INTO v_courier FROM public.user_profiles WHERE role = 'courier' ORDER BY id LIMIT 1;
  IF v_courier IS NULL THEN RAISE EXCEPTION 'OPZET: geen koerier in user_profiles.'; END IF;
  SELECT id INTO v_a FROM public.pharmacies ORDER BY id LIMIT 1;
  SELECT id INTO v_b FROM public.pharmacies WHERE id <> v_a ORDER BY id LIMIT 1;

  PERFORM public.set_pharmacy_rate(v_a, 30.00, 45.00, 55.00, 40.00, 10.00,
                                   current_date - 400, 'test 030');

  PERFORM set_config('request.jwt.claim.sub', v_planner::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_planner, 'role', 'authenticated')::text, true);

  -- ══ GEVAL 1 t/m 4: één dienst per soort werk ════════════════════════
  -- regular + fiets → 1 uur × 30 + 10 start = 40
  v_shift := test_030_shift(v_courier, v_a, v_day, '08:00', 'regular', 'bike');
  SELECT * INTO v_row FROM public.invoice_lines(v_a, v_day, v_day) WHERE shift_id = v_shift;
  IF v_row.hourly_rate <> 30.00 OR v_row.line_total <> 40.00 THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: tarief % en totaal %, verwacht 30 en 40.',
      v_row.hourly_rate, v_row.line_total;
  END IF;
  RAISE NOTICE 'GEVAL 1 geslaagd: een fietsdienst rekent met het fietstarief.';

  v_shift := test_030_shift(v_courier, v_a, v_day, '09:00', 'regular', 'car');
  SELECT * INTO v_row FROM public.invoice_lines(v_a, v_day, v_day) WHERE shift_id = v_shift;
  IF v_row.hourly_rate <> 45.00 OR v_row.line_total <> 55.00 THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: tarief % en totaal %, verwacht 45 en 55.',
      v_row.hourly_rate, v_row.line_total;
  END IF;
  RAISE NOTICE 'GEVAL 2 geslaagd: dezelfde dienst met de auto rekent met het autotarief.';

  v_shift := test_030_shift(v_courier, v_a, v_day, '10:00', 'institution', 'bike');
  SELECT * INTO v_row FROM public.invoice_lines(v_a, v_day, v_day) WHERE shift_id = v_shift;
  IF v_row.hourly_rate <> 55.00 THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: tarief %, verwacht 55 — bij een instellingsrit telt het vervoermiddel niet.',
      v_row.hourly_rate;
  END IF;
  RAISE NOTICE 'GEVAL 3 geslaagd: een instellingsrit heeft een eigen tarief, los van het vervoermiddel.';

  v_shift := test_030_shift(v_courier, v_a, v_day, '11:00', 'other_transport', 'car');
  SELECT * INTO v_row FROM public.invoice_lines(v_a, v_day, v_day) WHERE shift_id = v_shift;
  IF v_row.hourly_rate <> 40.00 THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: tarief %, verwacht 40 voor een klus.', v_row.hourly_rate;
  END IF;
  RAISE NOTICE 'GEVAL 4 geslaagd: klussen rekenen met het tarief voor overig transport.';

  -- ══ GEVAL 5: spoed blijft ongemoeid ═════════════════════════════════
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode, urgent_amount)
  VALUES (v_courier, 'urgent', v_day, '12:00', '13:00', 'planned', 'bike', 95.00)
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id, budgeted_minutes)
  VALUES (v_shift, v_a, 60);

  SELECT * INTO v_row FROM public.invoice_lines(v_a, v_day, v_day) WHERE shift_id = v_shift;
  IF v_row.line_total <> 95.00 OR v_row.hourly_rate IS NOT NULL THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: spoed geeft totaal % met tarief %, verwacht 95 zonder uurtarief.',
      v_row.line_total, v_row.hourly_rate;
  END IF;
  RAISE NOTICE 'GEVAL 5 geslaagd: spoed rekent nog steeds alleen het afgesproken bedrag.';

  -- ══ GEVAL 6: een vervoermiddel zonder tarief ════════════════════════
  -- De CHECK laat vandaag alleen bike en car toe; migratie 003 kondigt aan dat
  -- die ooit verruimd wordt. Dit is het geval dat dan niet stil op nul mag vallen.
  ALTER TABLE public.shifts DROP CONSTRAINT IF EXISTS shifts_transport_mode_check;

  v_shift := test_030_shift(v_courier, v_a, v_day, '13:30', 'regular', 'scooter');
  SELECT * INTO v_row FROM public.invoice_lines(v_a, v_day, v_day) WHERE shift_id = v_shift;
  IF v_row.line_total IS NOT NULL OR v_row.hours_amount IS NOT NULL THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: er staat een bedrag (% / %) voor een vervoermiddel zonder tarief.',
      v_row.line_total, v_row.hours_amount;
  END IF;
  IF NOT v_row.incomplete OR v_row.reason NOT LIKE '%scooter%' THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: geen leesbare reden voor het onbekende vervoermiddel (%).', v_row.reason;
  END IF;
  RAISE NOTICE 'GEVAL 6 geslaagd: een onbekend vervoermiddel geeft geen nul maar een melding (%).', v_row.reason;

  -- ══ GEVAL 7: soort werk zonder tarief bij deze apotheek ═════════════
  IF v_b IS NOT NULL THEN
    -- Apotheek B krijgt alleen een fietstarief.
    PERFORM public.set_pharmacy_rate(v_b, 25.00, NULL, NULL, NULL, 0.00,
                                     current_date - 400, 'test 030 — alleen fiets');

    v_shift := test_030_shift(v_courier, v_b, v_day, '14:30', 'institution', 'bike');
    SELECT * INTO v_row FROM public.invoice_lines(v_b, v_day, v_day) WHERE shift_id = v_shift;
    IF v_row.line_total IS NOT NULL THEN
      RAISE EXCEPTION 'GEVAL 7 GEFAALD: er staat een bedrag terwijl het instellingstarief ontbreekt.';
    END IF;
    IF NOT v_row.incomplete OR v_row.reason NOT LIKE '%instelling%' THEN
      RAISE EXCEPTION 'GEVAL 7 GEFAALD: de melding noemt niet welk tarief ontbreekt (%).', v_row.reason;
    END IF;
    RAISE NOTICE 'GEVAL 7 geslaagd: een ontbrekend tarief voor dít soort werk krijgt een eigen melding.';

    -- ══ GEVAL 8: starttarief 0 is een waarde ══════════════════════════
    v_shift := test_030_shift(v_courier, v_b, v_day, '15:30', 'regular', 'bike');
    SELECT * INTO v_row FROM public.invoice_lines(v_b, v_day, v_day) WHERE shift_id = v_shift;
    IF v_row.start_amount <> 0 THEN
      RAISE EXCEPTION 'GEVAL 8 GEFAALD: starttarief is %, verwacht 0.', v_row.start_amount;
    END IF;
    IF v_row.line_total <> 25.00 THEN
      RAISE EXCEPTION 'GEVAL 8 GEFAALD: totaal %, verwacht 25 (een uur fiets, geen starttarief).', v_row.line_total;
    END IF;
    IF v_row.incomplete THEN
      RAISE EXCEPTION 'GEVAL 8 GEFAALD: een starttarief van 0 is gemarkeerd als probleem (%).', v_row.reason;
    END IF;
    RAISE NOTICE 'GEVAL 8 geslaagd: een starttarief van 0 rekent gewoon en is geen uitzondering.';
  ELSE
    RAISE WARNING 'GEVAL 7 EN 8 OVERGESLAGEN: er is maar één apotheek.';
  END IF;

  RAISE NOTICE 'ALLE GEVALLEN GESLAAGD.';
END $$;

DROP FUNCTION IF EXISTS public.test_030_shift(UUID, TEXT, DATE, TIME, TEXT, TEXT);

ROLLBACK;
