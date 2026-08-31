-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 026: reden-opbouw en regels zonder duur
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 026 eerst (of proefdraai 026 met ROLLBACK en daarna dit).
-- De test van 025 blijft gelden; deze dekt alleen wat 026 verandert.
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: één transactie die op ROLLBACK eindigt.
--
-- WAT DE TEST DEKT
--   1. Een tak met een vaste zin  → geeft een reden terug in plaats van
--                                   "malformed array literal"
--   2. Geen duur, geen eindtijd   → de regel staat er, zonder bedragen, met de
--                                   markering
--   3. Geen tarief                → geen enkel bedrag, zodat de kolommen in het
--                                   overzicht optellen tot het eindtotaal
--   4. Gewone regel               → nog steeds compleet berekend (regressie)
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
  v_planner UUID;
  v_courier UUID;
  v_a       TEXT;
  v_b       TEXT;
  v_day     DATE := current_date - 5;
  v_old     DATE := current_date - 200;
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
  IF v_b IS NULL THEN RAISE EXCEPTION 'OPZET: er zijn minder dan twee apotheken.'; END IF;

  INSERT INTO public.pharmacy_rates (pharmacy_id, hourly_rate, start_rate, effective_from, note)
  VALUES (v_a, 60.00, 10.00, current_date - 400, 'test 026'),
         (v_b, 40.00,  5.00, current_date - 100, 'test 026')
  ON CONFLICT (pharmacy_id, effective_from) DO UPDATE
    SET hourly_rate = EXCLUDED.hourly_rate, start_rate = EXCLUDED.start_rate;

  PERFORM set_config('request.jwt.claim.sub', v_planner::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_planner, 'role', 'authenticated')::text, true);

  -- ══ GEVAL 1: een tak met een vaste zin ══════════════════════════════
  -- Een dienst zonder declaratie raakt de regel met de letterlijke tekst
  -- 'geen ingevulde declaratie; …'. Dat is precies de constructie die op
  -- "malformed array literal" stukliep.
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '08:00', '10:00', 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id, budgeted_minutes)
  VALUES (v_shift, v_a, 120);

  SELECT * INTO v_row FROM public.invoice_lines(v_a, v_day, v_day) WHERE shift_id = v_shift;
  IF NOT v_row.incomplete OR v_row.reason IS NULL THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: geen reden teruggekregen (incomplete=%, reason=%).',
      v_row.incomplete, v_row.reason;
  END IF;
  IF v_row.reason NOT LIKE '%geen ingevulde declaratie%' THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: onverwachte reden (%).', v_row.reason;
  END IF;
  RAISE NOTICE 'GEVAL 1 geslaagd: een vaste zin komt als reden terug (%).', v_row.reason;

  -- Diezelfde regel factureert de geplande uren: 120 min × €60 = €120 + €10.
  IF v_row.line_total <> 130.00 THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: totaal %, verwacht 130 (geplande uren).', v_row.line_total;
  END IF;

  -- ══ GEVAL 2: geen duur en geen geplande eindtijd ════════════════════
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '11:00', NULL, 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id, budgeted_minutes)
  VALUES (v_shift, v_a, 60);

  SELECT * INTO v_row FROM public.invoice_lines(v_a, v_day, v_day) WHERE shift_id = v_shift;
  IF v_row.shift_id IS NULL THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: de dienst valt weg uit het overzicht — dan mist de planner hem helemaal.';
  END IF;
  IF v_row.billed_minutes IS NOT NULL THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: % minuten gefactureerd terwijl er geen duur bekend is; onbekend is niet nul.',
      v_row.billed_minutes;
  END IF;
  IF v_row.line_total IS NOT NULL OR v_row.hours_amount IS NOT NULL OR v_row.start_amount IS NOT NULL THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: er staan bedragen (totaal %, uren %, start %) op een regel zonder duur.',
      v_row.line_total, v_row.hours_amount, v_row.start_amount;
  END IF;
  IF NOT v_row.incomplete OR v_row.reason NOT LIKE '%niets te factureren%' THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: de regel is niet gemarkeerd (reden: %).', v_row.reason;
  END IF;
  RAISE NOTICE 'GEVAL 2 geslaagd: zonder duur staat de regel er wél, zonder bedrag en met de markering.';

  -- ══ GEVAL 3: geen tarief → geen enkel bedrag ════════════════════════
  -- Apotheek B heeft pas een tarief vanaf 100 dagen terug. De koerier declareert
  -- reiskosten; zonder tarief mag ook dat bedrag niet blijven staan, anders telt
  -- de regel wel mee in het subtotaal Reis maar niet in het eindtotaal.
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_old, '08:00', '10:00', 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id, budgeted_minutes)
  VALUES (v_shift, v_b, 120);
  INSERT INTO public.shift_declarations (shift_id, courier_id, status, token_hash, token_expires_at,
                                         actual_start, actual_end, claims_travel,
                                         computed_reimbursable_km, rate_id)
  VALUES (v_shift, v_courier, 'submitted', public.declaration_hash_token('t-026-3'),
          now() + INTERVAL '30 days', '08:00', '10:00', true, 20.00,
          (SELECT id FROM public.reimbursement_rates
            WHERE transport_mode = 'bike' AND effective_from <= v_old
            ORDER BY effective_from DESC LIMIT 1));

  SELECT * INTO v_row FROM public.invoice_lines(v_b, v_old, v_old) WHERE shift_id = v_shift;
  IF v_row.line_total IS NOT NULL OR v_row.travel_amount IS NOT NULL THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: zonder tarief staat er nog een totaal (%) of reisbedrag (%).',
      v_row.line_total, v_row.travel_amount;
  END IF;
  IF NOT v_row.incomplete OR v_row.reason NOT LIKE '%geen tarief%' THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: ontbrekend tarief is niet gemeld (reden: %).', v_row.reason;
  END IF;
  RAISE NOTICE 'GEVAL 3 geslaagd: zonder totaal blijft er geen enkel los bedrag staan.';

  -- ══ GEVAL 4: een gewone regel blijft kloppen ════════════════════════
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '14:00', '16:00', 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id, budgeted_minutes)
  VALUES (v_shift, v_a, 120);
  INSERT INTO public.shift_declarations (shift_id, courier_id, status, token_hash, token_expires_at,
                                         actual_start, actual_end, claims_travel)
  VALUES (v_shift, v_courier, 'submitted', public.declaration_hash_token('t-026-4'),
          now() + INTERVAL '30 days', '14:00', '16:00', false);

  SELECT * INTO v_row FROM public.invoice_lines(v_a, v_day, v_day) WHERE shift_id = v_shift;
  IF v_row.billed_minutes <> 120 OR v_row.line_total <> 130.00 OR v_row.incomplete THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: % minuten, totaal %, gemarkeerd % — verwacht 120 / 130 / niet.',
      v_row.billed_minutes, v_row.line_total, v_row.incomplete;
  END IF;
  RAISE NOTICE 'GEVAL 4 geslaagd: een volledige regel wordt nog gewoon berekend.';

  RAISE NOTICE 'ALLE GEVALLEN GESLAAGD.';
END $$;

ROLLBACK;
