-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 032: factuursplitsing keten / filiaal
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 032 eerst (of proefdraai 032 met ROLLBACK en daarna dit).
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: één transactie die op ROLLBACK eindigt. De instelling
-- van de gebruikte keten wordt onderweg gewijzigd en draait mee terug.
--
-- OPSTELLING — apotheek A hoort bij een keten, rekent € 60 per uur en heeft een
-- starttarief van € 10. Diensten van twee uur gepland.
--
-- WAT DE TEST DEKT
--   1. Splitsing uit          → alles naar het filiaal, precies zoals voorheen
--   2. Aanzetten zonder adres → geweigerd
--   3. Splitsing aan, precies op plan → uren + start naar de keten
--   4. Goedgekeurd meerwerk   → alleen dát deel naar het filiaal
--   5. Korter gewerkt, splitsing aan → de keten betaalt het VOLLE blok
--   9. Korter gewerkt, splitsing uit → gewoon de werkelijke uren; model A is
--                               een variant en geen nieuwe hoofdregel
--   6. Reiskosten en onkosten → naar het filiaal
--   7. Spoed                  → volledig naar het filiaal
--   8. De delen tellen op tot line_total
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.test_032_shift(
  p_courier UUID, p_pharmacy TEXT, p_day DATE, p_start TIME, p_actual_end TIME
)
RETURNS UUID
LANGUAGE plpgsql AS $helper$
DECLARE v_shift UUID;
BEGIN
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time,
                             budgeted_end_time, status, transport_mode)
  VALUES (p_courier, 'regular', p_day, p_start, p_start + INTERVAL '2 hours',
          'planned', 'bike')
  RETURNING id INTO v_shift;

  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id, budgeted_minutes)
  VALUES (v_shift, p_pharmacy, 120);

  INSERT INTO public.shift_declarations (
    shift_id, courier_id, status, token_hash, token_expires_at,
    actual_start, actual_end, claims_travel)
  VALUES (v_shift, p_courier, 'submitted',
          public.declaration_hash_token('t-032-' || v_shift::TEXT),
          now() + INTERVAL '30 days', p_start, p_actual_end, false);

  RETURN v_shift;
END;
$helper$;

DO $$
DECLARE
  v_planner UUID;
  v_courier UUID;
  v_a       TEXT;
  v_group   TEXT;
  v_day     DATE := current_date - 6;
  v_shift   UUID;
  v_short   UUID;
  v_row     RECORD;
  v_msg     TEXT;
BEGIN
  SELECT id INTO v_planner FROM public.user_profiles
   WHERE role IN ('superuser','supervisor','admin') ORDER BY id LIMIT 1;
  IF v_planner IS NULL THEN RAISE EXCEPTION 'OPZET: geen planner in user_profiles.'; END IF;
  SELECT id INTO v_courier FROM public.user_profiles WHERE role = 'courier' ORDER BY id LIMIT 1;
  IF v_courier IS NULL THEN RAISE EXCEPTION 'OPZET: geen koerier in user_profiles.'; END IF;

  -- Een apotheek die aan een keten hangt; zonder keten valt er niets te splitsen.
  SELECT p.id, p."groupId" INTO v_a, v_group
  FROM public.pharmacies p WHERE p."groupId" IS NOT NULL ORDER BY p.id LIMIT 1;
  IF v_a IS NULL THEN
    RAISE EXCEPTION 'OPZET: geen apotheek met een groupId; zonder keten is er niets te splitsen.';
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_planner::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_planner, 'role', 'authenticated')::text, true);

  UPDATE public.invoice_settings SET deviation_pct = 500, extra_work_threshold_minutes = 15;
  PERFORM public.set_pharmacy_rate(v_a, 60.00, 60.00, 60.00, 60.00, 10.00,
                                   current_date - 400, 'test 032');
  PERFORM public.set_group_billing(v_group, NULL, false);

  -- ══ GEVAL 1: splitsing uit ══════════════════════════════════════════
  -- Twee uur gepland, twee uur gewerkt: 120 min × €60 = 120 + 10 start = 130.
  v_shift := public.test_032_shift(v_courier, v_a, v_day, '08:00', '10:00');
  SELECT * INTO v_row FROM public.invoice_lines(v_a, v_day, v_day) WHERE shift_id = v_shift;
  IF v_row.line_total <> 130.00 THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: totaal %, verwacht 130.', v_row.line_total;
  END IF;
  IF v_row.chain_amount <> 0 OR v_row.branch_amount <> 130.00 OR v_row.split_active THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: met de splitsing uit hoort alles naar het filiaal te gaan (keten %, filiaal %).',
      v_row.chain_amount, v_row.branch_amount;
  END IF;
  RAISE NOTICE 'GEVAL 1 geslaagd: zolang de splitsing uit staat verandert er niets.';

  -- ══ GEVAL 2: aanzetten zonder centraal adres ════════════════════════
  BEGIN
    PERFORM public.set_group_billing(v_group, NULL, true);
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: de splitsing ging aan zonder factuuradres.';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg LIKE 'GEVAL 2 GEFAALD%' THEN RAISE; END IF;
    RAISE NOTICE 'GEVAL 2 geslaagd: zonder centraal adres geen splitsing (%).', v_msg;
  END;

  PERFORM public.set_group_billing(v_group, 'keten@example.test', true);

  -- ══ GEVAL 3: precies op plan ════════════════════════════════════════
  SELECT * INTO v_row FROM public.invoice_lines(v_a, v_day, v_day) WHERE shift_id = v_shift;
  IF NOT v_row.split_active THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: de splitsing staat aan maar de regel weet dat niet.';
  END IF;
  IF v_row.chain_amount <> 130.00 OR v_row.branch_amount <> 0 THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: keten % en filiaal %, verwacht 130 en 0 — uren én starttarief horen bij het pakket.',
      v_row.chain_amount, v_row.branch_amount;
  END IF;
  RAISE NOTICE 'GEVAL 3 geslaagd: een dienst op plan gaat volledig naar de keten.';

  -- ══ GEVAL 4: goedgekeurd meerwerk ═══════════════════════════════════
  -- Drie uur gewerkt op twee uur gepland → 60 minuten meerwerk = € 60.
  v_shift := public.test_032_shift(v_courier, v_a, v_day, '11:00', '14:00');
  PERFORM public.extra_work_sweep(500);
  UPDATE public.extra_work SET status = 'approved', responded_at = now()
   WHERE shift_id = v_shift;

  SELECT * INTO v_row FROM public.invoice_lines(v_a, v_day, v_day) WHERE shift_id = v_shift;
  IF v_row.line_total <> 190.00 THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: totaal %, verwacht 190 (3 uur + start).', v_row.line_total;
  END IF;
  IF v_row.chain_amount <> 130.00 OR v_row.branch_amount <> 60.00 THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: keten % en filiaal %, verwacht 130 en 60 — alleen het meerwerk hoort bij het filiaal.',
      v_row.chain_amount, v_row.branch_amount;
  END IF;
  RAISE NOTICE 'GEVAL 4 geslaagd: het geplande deel gaat naar de keten, het meerwerk naar het filiaal.';

  -- ══ GEVAL 5: korter gewerkt, splitsing aan ══════════════════════════
  -- Eén uur op twee uur gepland. Het budget is een gereserveerd blok, dus de
  -- keten betaalt de volle twee uur: 120 min × €60 = 120 + 10 start = 130.
  v_short := public.test_032_shift(v_courier, v_a, v_day, '15:00', '16:00');
  SELECT * INTO v_row FROM public.invoice_lines(v_a, v_day, v_day) WHERE shift_id = v_short;
  IF v_row.chain_amount <> 130.00 THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: keten betaalt %, verwacht 130 — het budget is een gereserveerd blok.',
      v_row.chain_amount;
  END IF;
  IF v_row.branch_amount <> 0 THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: het filiaal krijgt % voor een dienst die korter duurde.', v_row.branch_amount;
  END IF;
  IF v_row.billed_minutes <> 60 THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: billed_minutes is %, verwacht 60 — wat er gewerkt is blijft zichtbaar.',
      v_row.billed_minutes;
  END IF;
  RAISE NOTICE 'GEVAL 5 geslaagd: bij een gesplitste keten betaalt die het volle gereserveerde blok.';

  -- ══ GEVAL 6: reiskosten en onkosten ═════════════════════════════════
  v_shift := public.test_032_shift(v_courier, v_a, v_day, '17:00', '19:00');
  UPDATE public.shift_declarations SET
    claims_travel = true, computed_reimbursable_km = 20.00,
    rate_id = (SELECT id FROM public.reimbursement_rates
                WHERE transport_mode = 'bike' AND effective_from <= v_day
                ORDER BY effective_from DESC LIMIT 1)
  WHERE shift_id = v_shift;
  INSERT INTO public.declaration_expenses (declaration_id, description, amount_eur)
  SELECT id, 'parkeren', 5.00 FROM public.shift_declarations WHERE shift_id = v_shift;

  SELECT * INTO v_row FROM public.invoice_lines(v_a, v_day, v_day) WHERE shift_id = v_shift;
  IF v_row.chain_amount <> 130.00 THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: keten betaalt %, verwacht 130 — reiskosten en onkosten horen bij het filiaal.',
      v_row.chain_amount;
  END IF;
  IF v_row.branch_amount <> COALESCE(v_row.travel_amount, 0) + COALESCE(v_row.expenses_amount, 0) THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: filiaal betaalt % maar reis + onkosten is % + %.',
      v_row.branch_amount, v_row.travel_amount, v_row.expenses_amount;
  END IF;
  RAISE NOTICE 'GEVAL 6 geslaagd: reiskosten en onkosten gaan naar het filiaal.';

  -- ══ GEVAL 7: spoed ══════════════════════════════════════════════════
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode, urgent_amount)
  VALUES (v_courier, 'urgent', v_day, '20:00', '21:00', 'planned', 'bike', 85.00)
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id, budgeted_minutes)
  VALUES (v_shift, v_a, 60);

  SELECT * INTO v_row FROM public.invoice_lines(v_a, v_day, v_day) WHERE shift_id = v_shift;
  IF v_row.branch_amount <> 85.00 OR v_row.chain_amount <> 0 THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: spoed gaf keten % en filiaal %, verwacht 0 en 85.',
      v_row.chain_amount, v_row.branch_amount;
  END IF;
  RAISE NOTICE 'GEVAL 7 geslaagd: een spoedrit is geen onderdeel van het pakket en gaat naar het filiaal.';

  -- ══ GEVAL 8: de delen kloppen met het geheel ════════════════════════
  IF EXISTS (
    SELECT 1 FROM public.invoice_lines(v_a, v_day, v_day)
    WHERE line_total IS NOT NULL
      AND round(COALESCE(chain_amount, 0) + COALESCE(branch_amount, 0), 2) <> round(line_total, 2)
  ) THEN
    RAISE EXCEPTION 'GEVAL 8 GEFAALD: er is een regel waar keten + filiaal niet optelt tot het totaal.';
  END IF;
  RAISE NOTICE 'GEVAL 8 geslaagd: op elke regel telt keten + filiaal op tot het regeltotaal.';

  -- ══ GEVAL 9: dezelfde korte dienst, maar splitsing uit ══════════════
  -- Dit is de bewaker die ertoe doet: model A geldt alleen binnen de splitsing.
  -- Overal elders blijft de regel van fase 7 staan — werkelijke uren, in beide
  -- richtingen, geen ondergrens. Eén uur × €60 + €10 start = €70.
  PERFORM public.set_group_billing(v_group, 'keten@example.test', false);

  SELECT * INTO v_row FROM public.invoice_lines(v_a, v_day, v_day) WHERE shift_id = v_short;
  IF v_row.line_total <> 70.00 THEN
    RAISE EXCEPTION 'GEVAL 9 GEFAALD: totaal %, verwacht 70. Zonder splitsing hoort een korter gewerkte dienst gewoon minder te kosten — model A mag niet overal gaan gelden.',
      v_row.line_total;
  END IF;
  IF v_row.chain_amount <> 0 OR v_row.branch_amount <> 70.00 THEN
    RAISE EXCEPTION 'GEVAL 9 GEFAALD: met de splitsing uit hoort alles naar het filiaal (keten %, filiaal %).',
      v_row.chain_amount, v_row.branch_amount;
  END IF;
  RAISE NOTICE 'GEVAL 9 geslaagd: zonder splitsing blijft de bestaande regel onveranderd gelden.';

  RAISE NOTICE 'ALLE GEVALLEN GESLAAGD.';
END $$;

DROP FUNCTION IF EXISTS public.test_032_shift(UUID, TEXT, DATE, TIME, TIME);

ROLLBACK;
