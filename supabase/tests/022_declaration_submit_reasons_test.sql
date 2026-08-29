-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 022: de melding past bij wat er aan de hand is
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 022 eerst (of proefdraai 022 met ROLLBACK en daarna dit).
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: één transactie die op ROLLBACK eindigt.
--
-- WAT DE TEST DEKT
--   1. Gewoon indienen           → werkt nog steeds (de regressie die telt)
--   2. Onbekend token            → 28000, en niets over wat er wél bestaat
--   3. Verlopen link             → 45001
--   4. Betwist door de planning  → 45002
--   5. Al goedgekeurd            → 45003
--   6. Goedgekeurd ÉN verlopen   → 45003; de status is het nuttigste antwoord
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
  v_courier UUID;
  v_home    TEXT;
  v_day     DATE := current_date - 2;
  v_shift   UUID;
  v_dec     UUID;
  v_state   TEXT;
  v_msg     TEXT;

  -- De tokens op een rij: een geldige, en vier die om verschillende redenen
  -- geweigerd horen te worden. Alleen de hashes komen in de database.
  v_tokens  TEXT[] := ARRAY['t-ok', 't-verlopen', 't-betwist', 't-goedgekeurd', 't-beide'];
BEGIN
  SELECT id INTO v_courier FROM public.user_profiles WHERE role = 'courier' ORDER BY id LIMIT 1;
  IF v_courier IS NULL THEN RAISE EXCEPTION 'OPZET: geen koerier in user_profiles.'; END IF;
  SELECT id INTO v_home FROM public.pharmacies ORDER BY id LIMIT 1;

  -- ── GEVAL 1: gewoon indienen werkt nog ───────────────────────────────
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '08:00', '12:00', 'planned', 'bike')
  RETURNING id INTO v_shift;
  IF v_home IS NOT NULL THEN
    INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id) VALUES (v_shift, v_home);
  END IF;

  INSERT INTO public.shift_declarations (shift_id, courier_id, token_hash, token_expires_at)
  VALUES (v_shift, v_courier, public.declaration_hash_token(v_tokens[1]), now() + INTERVAL '30 days')
  RETURNING id INTO v_dec;

  PERFORM public.declaration_submit(v_tokens[1], TIME '08:05', TIME '12:20', false, NULL, NULL);

  IF (SELECT status FROM public.shift_declarations WHERE id = v_dec) <> 'submitted' THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: een gewone opgave werd niet vastgelegd.';
  END IF;
  RAISE NOTICE 'GEVAL 1 geslaagd: indienen werkt nog gewoon.';

  -- ── GEVAL 2: onbekend token ──────────────────────────────────────────
  BEGIN
    PERFORM public.declaration_submit('bestaat-niet-' || gen_random_uuid()::TEXT,
                                      TIME '08:00', TIME '12:00', false, NULL, NULL);
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: een onbekend token werd geaccepteerd.';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_msg LIKE 'GEVAL 2 GEFAALD%' THEN RAISE; END IF;
    IF v_state <> '28000' THEN
      RAISE EXCEPTION 'GEVAL 2 GEFAALD: SQLSTATE % in plaats van 28000 (%).', v_state, v_msg;
    END IF;
    IF v_msg <> 'Deze link is niet (meer) geldig.' THEN
      RAISE EXCEPTION 'GEVAL 2 GEFAALD: de melding voor een onbekend token is veranderd (%). Die moet nietszeggend blijven.', v_msg;
    END IF;
    RAISE NOTICE 'GEVAL 2 geslaagd: een onbekend token verraadt niets.';
  END;

  -- ── Drie declaraties die om verschillende redenen dicht zitten ───────
  -- Verlopen (status blijft open).
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '13:00', '15:00', 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_declarations (shift_id, courier_id, token_hash, token_expires_at)
  VALUES (v_shift, v_courier, public.declaration_hash_token(v_tokens[2]), now() - INTERVAL '1 day');

  -- Betwist, link nog geldig.
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '15:30', '17:00', 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_declarations (shift_id, courier_id, status, token_hash, token_expires_at)
  VALUES (v_shift, v_courier, 'disputed', public.declaration_hash_token(v_tokens[3]), now() + INTERVAL '30 days');

  -- Goedgekeurd, link nog geldig.
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '17:30', '19:00', 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_declarations (shift_id, courier_id, status, token_hash, token_expires_at)
  VALUES (v_shift, v_courier, 'approved', public.declaration_hash_token(v_tokens[4]), now() + INTERVAL '30 days');

  -- Goedgekeurd ÉN verlopen.
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '19:30', '21:00', 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_declarations (shift_id, courier_id, status, token_hash, token_expires_at)
  VALUES (v_shift, v_courier, 'approved', public.declaration_hash_token(v_tokens[5]), now() - INTERVAL '1 day');

  -- ── GEVAL 3: verlopen ────────────────────────────────────────────────
  BEGIN
    PERFORM public.declaration_submit(v_tokens[2], TIME '13:00', TIME '15:10', false, NULL, NULL);
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: er kon ingediend worden op een verlopen link.';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_msg LIKE 'GEVAL 3 GEFAALD%' THEN RAISE; END IF;
    IF v_state <> '45001' THEN
      RAISE EXCEPTION 'GEVAL 3 GEFAALD: verlopen link gaf SQLSTATE % (%), verwacht 45001.', v_state, v_msg;
    END IF;
    IF v_msg NOT LIKE '%verlopen%' THEN
      RAISE EXCEPTION 'GEVAL 3 GEFAALD: de melding noemt niet dat de link verlopen is (%).', v_msg;
    END IF;
    RAISE NOTICE 'GEVAL 3 geslaagd: een verlopen link zegt dat ook (%).', v_msg;
  END;

  -- ── GEVAL 4: betwist ─────────────────────────────────────────────────
  BEGIN
    PERFORM public.declaration_submit(v_tokens[3], TIME '15:30', TIME '17:10', false, NULL, NULL);
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: er kon ingediend worden op een betwiste declaratie.';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_msg LIKE 'GEVAL 4 GEFAALD%' THEN RAISE; END IF;
    IF v_state <> '45002' THEN
      RAISE EXCEPTION 'GEVAL 4 GEFAALD: betwist gaf SQLSTATE % (%), verwacht 45002.', v_state, v_msg;
    END IF;
    IF v_msg LIKE '%niet (meer) geldig%' THEN
      RAISE EXCEPTION 'GEVAL 4 GEFAALD: een betwiste declaratie krijgt nog de melding dat de link ongeldig is.';
    END IF;
    RAISE NOTICE 'GEVAL 4 geslaagd: bij een betwiste declaratie staat er wat er speelt (%).', v_msg;
  END;

  -- ── GEVAL 5: goedgekeurd ─────────────────────────────────────────────
  BEGIN
    PERFORM public.declaration_submit(v_tokens[4], TIME '17:30', TIME '19:10', false, NULL, NULL);
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: er kon ingediend worden op een goedgekeurde declaratie.';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_msg LIKE 'GEVAL 5 GEFAALD%' THEN RAISE; END IF;
    IF v_state <> '45003' THEN
      RAISE EXCEPTION 'GEVAL 5 GEFAALD: goedgekeurd gaf SQLSTATE % (%), verwacht 45003.', v_state, v_msg;
    END IF;
    RAISE NOTICE 'GEVAL 5 geslaagd: een goedgekeurde declaratie zegt dat hij vaststaat (%).', v_msg;
  END;

  -- ── GEVAL 6: goedgekeurd én verlopen → de status wint ────────────────
  BEGIN
    PERFORM public.declaration_submit(v_tokens[5], TIME '19:30', TIME '21:10', false, NULL, NULL);
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: er kon ingediend worden.';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_msg LIKE 'GEVAL 6 GEFAALD%' THEN RAISE; END IF;
    IF v_state <> '45003' THEN
      RAISE EXCEPTION 'GEVAL 6 GEFAALD: SQLSTATE % (%), verwacht 45003 — goedgekeurd is nuttiger dan verlopen.', v_state, v_msg;
    END IF;
    RAISE NOTICE 'GEVAL 6 geslaagd: bij goedgekeurd én verlopen wint de status.';
  END;

  RAISE NOTICE 'ALLE GEVALLEN GESLAAGD.';
END $$;

ROLLBACK;
