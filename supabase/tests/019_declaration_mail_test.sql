-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 019: sweep, leeftijdscontrole, token en invulpagina
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 018 en 019 eerst.
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: één transactie die op ROLLBACK eindigt. De sweep pakt
-- binnen die transactie ook echte afgelopen diensten op; dat verdwijnt met de
-- rollback en alle tellingen hieronder zijn afgebakend op de testdiensten.
--
-- WAT DE TEST DEKT
--   1. Afgelopen dienst        → declaratie + één outbox-bericht (shift_followup)
--   2. Tweede sweep            → geen tweede declaratie en geen tweede bericht
--   3. Dienst die nog loopt    → niets
--   4. Dienst vóór active_from → niets (de vloer die de eerste run beschermt)
--   5. Te oude dienst          → niets
--   6. Token uitgeven          → werkt één keer; alleen de hash staat in de DB
--   7. Onbekend token          → nul rijen, geen lek over wat er wél bestaat
--   8. Indienen                → status, invoer en herberekening kloppen
--   9. Oude wachtende post     → 'expired', niet stilzwijgend blijven staan
--  10. Beoordeeld              → de link doet niets meer
--  11. Nabericht zonder link  → terug in de wachtrij, niet als verstuurd afgevinkt
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
  v_courier UUID;
  v_home    TEXT;
  v_s_done  UUID;   -- afgelopen dienst
  v_s_busy  UUID;   -- dienst die nog loopt
  v_s_early UUID;   -- dienst vóór active_from
  v_s_old   UUID;   -- te oude dienst
  v_dec     UUID;
  v_token   TEXT;
  v_hash    TEXT;
  v_n       INT;
  v_row     RECORD;
  v_msg     TEXT;
BEGIN
  -- ── Voorbereiding ────────────────────────────────────────────────────
  SELECT id INTO v_courier FROM public.user_profiles WHERE role = 'courier' ORDER BY id LIMIT 1;
  IF v_courier IS NULL THEN RAISE EXCEPTION 'OPZET: geen koerier in user_profiles.'; END IF;
  SELECT id INTO v_home FROM public.pharmacies ORDER BY id LIMIT 1;
  IF v_home IS NULL THEN RAISE EXCEPTION 'OPZET: geen apotheek in pharmacies.'; END IF;

  UPDATE public.user_profiles SET home_pharmacy_id = v_home WHERE id = v_courier;
  INSERT INTO public.courier_distances (courier_id, pharmacy_id, distance_km, source)
  VALUES (v_courier, v_home, 25.00, 'manual')
  ON CONFLICT (courier_id, pharmacy_id) DO UPDATE SET distance_km = 25.00;

  -- Eigen tarief met drempel 10, zodat de test niet afhangt van wat er in
  -- reimbursement_rates staat.
  INSERT INTO public.reimbursement_rates (transport_mode, rate_per_km, threshold_km, effective_from, note)
  VALUES ('bike', 0.2000, 10, current_date - 2, 'test 019')
  ON CONFLICT (transport_mode, effective_from) DO UPDATE
    SET rate_per_km = EXCLUDED.rate_per_km, threshold_km = EXCLUDED.threshold_km;

  UPDATE public.declaration_settings
     SET active_from = current_date - 3, max_age_days = 5, token_valid_days = 30;

  -- Vier diensten: één afgelopen, één die nog loopt, één vóór de vloer en één
  -- die te oud is.
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', current_date - 1, '08:00', '12:00', 'planned', 'bike')
  RETURNING id INTO v_s_done;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id) VALUES (v_s_done, v_home);

  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', current_date + 2, '08:00', '12:00', 'planned', 'bike')
  RETURNING id INTO v_s_busy;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id) VALUES (v_s_busy, v_home);

  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', current_date - 4, '08:00', '12:00', 'planned', 'bike')
  RETURNING id INTO v_s_early;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id) VALUES (v_s_early, v_home);

  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', current_date - 30, '08:00', '12:00', 'planned', 'bike')
  RETURNING id INTO v_s_old;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id) VALUES (v_s_old, v_home);

  -- ── GEVAL 1: de sweep pakt de afgelopen dienst op ────────────────────
  PERFORM public.declaration_sweep(1000);

  SELECT id INTO v_dec FROM public.shift_declarations WHERE shift_id = v_s_done;
  IF v_dec IS NULL THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: de afgelopen dienst kreeg geen declaratie.';
  END IF;

  SELECT count(*) INTO v_n FROM public.mail_outbox
   WHERE kind = 'shift_followup' AND subject_id = v_s_done;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: % outbox-berichten voor één dienst, verwacht 1.', v_n;
  END IF;

  -- De berekening staat er meteen op; alleen de kilometers ontbreken nog.
  SELECT * INTO v_row FROM public.shift_declarations WHERE id = v_dec;
  IF v_row.computed_rule <> 'above_threshold' OR v_row.computed_distance_km <> 25.00 THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: berekening ontbreekt of klopt niet (regel %, afstand %).',
      v_row.computed_rule, v_row.computed_distance_km;
  END IF;
  IF v_row.status <> 'open' THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: nieuwe declaratie heeft status %, verwacht open.', v_row.status;
  END IF;
  RAISE NOTICE 'GEVAL 1 geslaagd: afgelopen dienst levert een declaratie met berekening en één bericht op.';

  -- ── GEVAL 2: nog een keer sweepen verandert niets ────────────────────
  PERFORM public.declaration_sweep(1000);

  SELECT count(*) INTO v_n FROM public.shift_declarations WHERE shift_id = v_s_done;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: % declaraties voor dezelfde dienst — de unique op shift_id doet zijn werk niet.', v_n;
  END IF;
  SELECT count(*) INTO v_n FROM public.mail_outbox
   WHERE kind = 'shift_followup' AND subject_id = v_s_done;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: een tweede sweep leverde % berichten op.', v_n;
  END IF;
  RAISE NOTICE 'GEVAL 2 geslaagd: de sweep is idempotent.';

  -- ── GEVAL 3, 4, 5: wat er buiten het venster valt ────────────────────
  IF EXISTS (SELECT 1 FROM public.shift_declarations WHERE shift_id = v_s_busy) THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: er is nagevraagd over een dienst die nog moet plaatsvinden.';
  END IF;
  RAISE NOTICE 'GEVAL 3 geslaagd: een dienst die nog niet af is wordt overgeslagen.';

  IF EXISTS (SELECT 1 FROM public.shift_declarations WHERE shift_id = v_s_early) THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: een dienst van vóór active_from is opgepakt — de vloer beschermt de eerste run niet.';
  END IF;
  RAISE NOTICE 'GEVAL 4 geslaagd: diensten van vóór active_from blijven buiten beeld.';

  IF EXISTS (SELECT 1 FROM public.shift_declarations WHERE shift_id = v_s_old) THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: een dienst ouder dan max_age_days is alsnog opgepakt.';
  END IF;
  RAISE NOTICE 'GEVAL 5 geslaagd: te oude diensten worden niet meer nagevraagd.';

  -- ── GEVAL 6: token uitgeven ──────────────────────────────────────────
  SELECT token_hash INTO v_hash FROM public.shift_declarations WHERE id = v_dec;
  SELECT token INTO v_token FROM public.declaration_issue_token(v_dec);

  IF v_token IS NULL OR length(v_token) < 64 THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: token is te kort of leeg (%).', v_token;
  END IF;
  IF EXISTS (SELECT 1 FROM public.shift_declarations WHERE id = v_dec AND token_hash = v_token) THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: het token zelf staat in de database — er hoort alleen een hash te staan.';
  END IF;
  IF (SELECT token_hash FROM public.shift_declarations WHERE id = v_dec) = v_hash THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: de hash is niet vervangen bij het uitgeven.';
  END IF;

  SELECT * INTO v_row FROM public.declaration_by_token(v_token);
  IF v_row.declaration_id IS DISTINCT FROM v_dec THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: het token wijst niet naar de eigen declaratie.';
  END IF;
  IF v_row.shift_date <> current_date - 1 OR v_row.start_time <> '08:00' THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: de pagina toont de verkeerde dienstgegevens (% %).', v_row.shift_date, v_row.start_time;
  END IF;
  RAISE NOTICE 'GEVAL 6 geslaagd: het token geeft toegang tot precies één declaratie en staat nergens opgeslagen.';

  -- ── GEVAL 7: een onbekend token levert niets op ──────────────────────
  IF EXISTS (SELECT 1 FROM public.declaration_by_token('dit-token-bestaat-niet')) THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: een onbekend token gaf toch een rij.';
  END IF;
  RAISE NOTICE 'GEVAL 7 geslaagd: een onbekend token geeft nul rijen.';

  -- ── GEVAL 8: indienen ────────────────────────────────────────────────
  PERFORM public.declaration_submit(v_token, TIME '07:55', TIME '12:40', false, NULL, '  eerder klaar  ');

  SELECT * INTO v_row FROM public.shift_declarations WHERE id = v_dec;
  IF v_row.status <> 'submitted' OR v_row.submitted_at IS NULL THEN
    RAISE EXCEPTION 'GEVAL 8 GEFAALD: status is % na indienen.', v_row.status;
  END IF;
  IF v_row.actual_start <> TIME '07:55' OR v_row.actual_end <> TIME '12:40' THEN
    RAISE EXCEPTION 'GEVAL 8 GEFAALD: de opgegeven tijden zijn niet vastgelegd.';
  END IF;
  IF v_row.courier_note <> 'eerder klaar' THEN
    RAISE EXCEPTION 'GEVAL 8 GEFAALD: de opmerking is niet (getrimd) opgeslagen: %.', v_row.courier_note;
  END IF;
  IF v_row.computed_reimbursable_km <> 15.00 THEN
    RAISE EXCEPTION 'GEVAL 8 GEFAALD: herberekening na indienen gaf % km, verwacht 15.', v_row.computed_reimbursable_km;
  END IF;
  RAISE NOTICE 'GEVAL 8 geslaagd: de invoer is vastgelegd en de berekening is bijgewerkt.';

  -- ── GEVAL 9: oude wachtende post vervalt ─────────────────────────────
  -- Het bericht van de te oude dienst bestaat nog niet (geval 5), dus we zetten
  -- er zelf een neer alsof hij ooit is ingeschreven en blijven staan.
  INSERT INTO public.mail_outbox (courier_id, kind, subject_type, subject_id, payload)
  VALUES (v_courier, 'shift_followup', 'shift', v_s_old,
          jsonb_build_object('declaration_id', gen_random_uuid(),
                             'shift_date', (current_date - 30)::TEXT));

  SELECT public.declaration_expire_stale() INTO v_n;
  IF v_n < 1 THEN
    RAISE EXCEPTION 'GEVAL 9 GEFAALD: de leeftijdscontrole liet het oude bericht staan.';
  END IF;
  IF (SELECT status FROM public.mail_outbox WHERE subject_id = v_s_old AND kind = 'shift_followup') <> 'expired' THEN
    RAISE EXCEPTION 'GEVAL 9 GEFAALD: het oude bericht staat niet op expired.';
  END IF;
  IF (SELECT status FROM public.mail_outbox WHERE subject_id = v_s_done AND kind = 'shift_followup') <> 'pending' THEN
    RAISE EXCEPTION 'GEVAL 9 GEFAALD: een vers bericht is meegenomen in de opschoning.';
  END IF;
  RAISE NOTICE 'GEVAL 9 geslaagd: te oude post vervalt zichtbaar, verse post blijft staan.';

  -- ── GEVAL 10: na beoordeling doet de link niets meer ─────────────────
  UPDATE public.shift_declarations SET status = 'approved', reviewed_at = now() WHERE id = v_dec;

  IF EXISTS (SELECT 1 FROM public.declaration_by_token(v_token)) THEN
    RAISE EXCEPTION 'GEVAL 10 GEFAALD: de link werkt nog na goedkeuring.';
  END IF;

  BEGIN
    PERFORM public.declaration_submit(v_token, TIME '06:00', TIME '07:00', false, NULL, NULL);
    RAISE EXCEPTION 'GEVAL 10 GEFAALD: er kon nog ingediend worden op een goedgekeurde declaratie.';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg LIKE 'GEVAL 10 GEFAALD%' THEN RAISE; END IF;
    RAISE NOTICE 'GEVAL 10 geslaagd: indienen wordt geweigerd (%).', v_msg;
  END;

  -- ── GEVAL 11: een geclaimd nabericht zonder link gaat terug in de rij ─
  -- De verzender legt één uitkomst op de hele bundel vast. Een nabericht
  -- waarvoor geen invullink gemaakt kon worden moet daarom uit die bundel, en
  -- niet als verstuurd eindigen.
  UPDATE public.mail_outbox
     SET status = 'sending', claimed_at = now()
   WHERE subject_id = v_s_done AND kind = 'shift_followup';

  SELECT public.declaration_release(
    ARRAY(SELECT id FROM public.mail_outbox WHERE subject_id = v_s_done AND kind = 'shift_followup')
  ) INTO v_n;

  IF v_n <> 1 THEN
    RAISE EXCEPTION 'GEVAL 11 GEFAALD: % rijen teruggezet, verwacht 1.', v_n;
  END IF;
  SELECT * INTO v_row FROM public.mail_outbox
   WHERE subject_id = v_s_done AND kind = 'shift_followup';
  IF v_row.status <> 'pending' OR v_row.claimed_at IS NOT NULL THEN
    RAISE EXCEPTION 'GEVAL 11 GEFAALD: rij staat op % met claimed_at %.', v_row.status, v_row.claimed_at;
  END IF;
  RAISE NOTICE 'GEVAL 11 geslaagd: een nabericht zonder invullink blijft wachten in plaats van te verdwijnen.';

  RAISE NOTICE 'ALLE GEVALLEN GESLAAGD.';
END $$;

ROLLBACK;
