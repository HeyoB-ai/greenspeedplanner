-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 023: de link opent ook na beoordeling
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 023 eerst (of proefdraai 023 met ROLLBACK en daarna dit).
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: één transactie die op ROLLBACK eindigt.
--
-- WAT DE TEST DEKT
--   1. Open declaratie          → komt terug, zoals altijd
--   2. Goedgekeurd              → komt nu ook terug, met de status erbij
--   3. Betwist                  → komt terug, mét de reden van de planning
--   4. Verlopen link            → nog steeds nul rijen, ook al is de status open
--   5. Onbekend token           → nul rijen
--   6. De ingevulde gegevens    → staan in het antwoord, zodat de pagina ze kan
--                                 tonen zonder invoervelden
--   7. declaration_submit()     → weigert een goedgekeurde declaratie nog steeds
--                                 met de melding uit migratie 022
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
  v_courier UUID;
  v_home    TEXT;
  v_day     DATE := current_date - 2;
  v_shift   UUID;
  v_row     RECORD;
  v_i       INT;
  v_case    TEXT;
  v_state   TEXT;   -- SQLSTATE bij geval 7
  v_msg     TEXT;
BEGIN
  SELECT id INTO v_courier FROM public.user_profiles WHERE role = 'courier' ORDER BY id LIMIT 1;
  IF v_courier IS NULL THEN RAISE EXCEPTION 'OPZET: geen koerier in user_profiles.'; END IF;
  SELECT id INTO v_home FROM public.pharmacies ORDER BY id LIMIT 1;

  -- Vier declaraties, elk met een eigen token en een eigen uur op de dag.
  -- 1: open  2: goedgekeurd  3: betwist  4: open maar verlopen
  FOR v_i IN 1..4 LOOP
    v_case := (ARRAY['open', 'approved', 'disputed', 'verlopen'])[v_i];

    INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                               status, transport_mode)
    VALUES (v_courier, 'regular', v_day,
            TIME '08:00' + make_interval(hours => v_i - 1),
            TIME '09:30' + make_interval(hours => v_i - 1),
            'planned', 'bike')
    RETURNING id INTO v_shift;
    IF v_home IS NOT NULL THEN
      INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id) VALUES (v_shift, v_home);
    END IF;

    -- Bij 'approved' en 'disputed' staat er ook ingevulde opgave in: dat is wat
    -- de leesweergave straks moet tonen.
    INSERT INTO public.shift_declarations
      (shift_id, courier_id, status, token_hash, token_expires_at,
       actual_start, actual_end, claims_travel, courier_note, submitted_at, review_note)
    VALUES (
      v_shift, v_courier,
      CASE WHEN v_case = 'verlopen' THEN 'open' ELSE v_case END,
      public.declaration_hash_token('t-023-' || v_case),
      CASE WHEN v_case = 'verlopen' THEN now() - INTERVAL '1 day' ELSE now() + INTERVAL '30 days' END,
      CASE WHEN v_case IN ('approved', 'disputed') THEN TIME '08:05' END,
      CASE WHEN v_case IN ('approved', 'disputed') THEN TIME '12:40' END,
      CASE WHEN v_case IN ('approved', 'disputed') THEN false END,
      CASE WHEN v_case IN ('approved', 'disputed') THEN 'later klaar dan gepland' END,
      CASE WHEN v_case IN ('approved', 'disputed') THEN now() - INTERVAL '1 day' END,
      CASE WHEN v_case = 'disputed' THEN 'De eindtijd klopt niet met de scans; bel even.' END);
  END LOOP;

  -- ── GEVAL 1: open ────────────────────────────────────────────────────
  SELECT * INTO v_row FROM public.declaration_by_token('t-023-open');
  IF v_row.declaration_id IS NULL OR v_row.status <> 'open' THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: een openstaande declaratie komt niet meer terug.';
  END IF;
  RAISE NOTICE 'GEVAL 1 geslaagd: een openstaande declaratie komt gewoon terug.';

  -- ── GEVAL 2: goedgekeurd ─────────────────────────────────────────────
  SELECT * INTO v_row FROM public.declaration_by_token('t-023-approved');
  IF v_row.declaration_id IS NULL THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: een goedgekeurde declaratie geeft nog steeds nul rijen — de koerier ziet dan "link werkt niet meer".';
  END IF;
  IF v_row.status <> 'approved' THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: status is %, verwacht approved.', v_row.status;
  END IF;
  RAISE NOTICE 'GEVAL 2 geslaagd: een goedgekeurde declaratie komt terug, met de status erbij.';

  -- ── GEVAL 3: betwist, mét de reden ───────────────────────────────────
  SELECT * INTO v_row FROM public.declaration_by_token('t-023-disputed');
  IF v_row.status <> 'disputed' THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: status is %, verwacht disputed.', v_row.status;
  END IF;
  IF v_row.review_note IS NULL OR v_row.review_note NOT LIKE '%scans%' THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: de reden van de planning komt niet mee (%). Zonder die tekst weet de koerier niets.', v_row.review_note;
  END IF;
  RAISE NOTICE 'GEVAL 3 geslaagd: bij een betwiste declaratie komt de reden mee.';

  -- ── GEVAL 4: verlopen blijft dicht ───────────────────────────────────
  IF EXISTS (SELECT 1 FROM public.declaration_by_token('t-023-verlopen')) THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: een verlopen link geeft nog gegevens terug.';
  END IF;
  RAISE NOTICE 'GEVAL 4 geslaagd: een verlopen link blijft afgewezen, ook bij status open.';

  -- ── GEVAL 5: onbekend token ──────────────────────────────────────────
  IF EXISTS (SELECT 1 FROM public.declaration_by_token('bestaat-niet-' || gen_random_uuid()::TEXT)) THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: een onbekend token gaf een rij.';
  END IF;
  RAISE NOTICE 'GEVAL 5 geslaagd: een onbekend token geeft nog steeds niets.';

  -- ── GEVAL 6: de ingevulde gegevens komen mee ─────────────────────────
  SELECT * INTO v_row FROM public.declaration_by_token('t-023-approved');
  IF v_row.actual_start <> '08:05' OR v_row.actual_end <> '12:40'
     OR v_row.courier_note IS NULL OR v_row.submitted_at IS NULL THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: de leesweergave mist gegevens (% - %, opmerking %).',
      v_row.actual_start, v_row.actual_end, v_row.courier_note;
  END IF;
  RAISE NOTICE 'GEVAL 6 geslaagd: wat de koerier invulde komt mee, zodat de pagina het kan tonen.';

  -- ── GEVAL 7: opslaan blijft geweigerd (migratie 022) ─────────────────
  BEGIN
    PERFORM public.declaration_submit('t-023-approved', TIME '08:00', TIME '12:00', false, NULL, NULL);
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: een goedgekeurde declaratie kon alsnog overschreven worden.';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_msg LIKE 'GEVAL 7 GEFAALD%' THEN RAISE; END IF;
    IF v_state <> '45003' THEN
      RAISE EXCEPTION 'GEVAL 7 GEFAALD: SQLSTATE % (%), verwacht 45003 uit migratie 022.', v_state, v_msg;
    END IF;
    RAISE NOTICE 'GEVAL 7 geslaagd: lezen mag, opslaan niet — de meldingen uit 022 staan nog.';
  END;

  RAISE NOTICE 'ALLE GEVALLEN GESLAAGD.';
END $$;

ROLLBACK;
