-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 031: goedkeuring van meerwerk
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 031 eerst (of proefdraai 031 met ROLLBACK en daarna dit).
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: één transactie die op ROLLBACK eindigt.
--
-- OPSTELLING — drempel 15 minuten, reactietermijn 48 uur. Apotheek A rekent
-- € 60 per uur voor een fietsdienst, geen starttarief, zodat een uur precies
-- € 60 is en het rekenwerk in de gevallen 7 t/m 9 te volgen blijft.
--
-- WAT DE TEST DEKT
--   1. Uitloop onder de drempel   → geen melding
--   2. Uitloop erboven            → melding 'new', met de toelichting gekopieerd
--   3. Twee apotheken             → elk zijn eigen deel, naar rato
--   4. Vrijgeven zonder adres     → geweigerd, en er gaat niets de deur uit
--   5. Vrijgeven mét adres        → 'released' + één outbox-rij naar de apotheek
--   6. Token, lezen, antwoorden   → approved, en de link blijft daarna lezen
--   7. Factuur bij 'released'     → alleen de geplande uren, met markering
--   8. Factuur bij 'approved'     → de volle uren
--   9. Factuur bij 'expired'      → de volle uren, met een eigen markering
--  10. De koerier blijft ongemoeid → zijn declaratie verandert nergens van
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
  v_planner UUID;
  v_courier UUID;
  v_a       TEXT;
  v_b       TEXT;
  v_day     DATE := current_date - 2;
  v_shift   UUID;
  v_shift2  UUID;
  v_dec     UUID;
  v_xw      UUID;
  v_xw_b    UUID;
  v_token   TEXT;
  v_row     RECORD;
  v_n       INT;
  v_state   TEXT;
  v_msg     TEXT;
  v_before  NUMERIC;
BEGIN
  SELECT id INTO v_planner FROM public.user_profiles
   WHERE role IN ('superuser','supervisor','admin') ORDER BY id LIMIT 1;
  IF v_planner IS NULL THEN RAISE EXCEPTION 'OPZET: geen planner in user_profiles.'; END IF;
  SELECT id INTO v_courier FROM public.user_profiles WHERE role = 'courier' ORDER BY id LIMIT 1;
  IF v_courier IS NULL THEN RAISE EXCEPTION 'OPZET: geen koerier in user_profiles.'; END IF;
  SELECT id INTO v_a FROM public.pharmacies ORDER BY id LIMIT 1;
  SELECT id INTO v_b FROM public.pharmacies WHERE id <> v_a ORDER BY id LIMIT 1;
  IF v_b IS NULL THEN RAISE EXCEPTION 'OPZET: er zijn minder dan twee apotheken.'; END IF;

  UPDATE public.invoice_settings
     SET extra_work_threshold_minutes = 15, extra_work_respond_hours = 48, deviation_pct = 500;

  PERFORM set_config('request.jwt.claim.sub', v_planner::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_planner, 'role', 'authenticated')::text, true);

  PERFORM public.set_pharmacy_rate(v_a, 60.00, 60.00, 60.00, 60.00, 0.00,
                                   current_date - 400, 'test 031');
  PERFORM public.set_pharmacy_rate(v_b, 60.00, 60.00, 60.00, 60.00, 0.00,
                                   current_date - 400, 'test 031');
  -- Adressen bewust nog leeg; geval 4 heeft dat nodig.
  PERFORM public.set_pharmacy_billing_email(v_a, NULL);
  PERFORM public.set_pharmacy_billing_email(v_b, NULL);

  -- ══ GEVAL 1: tien minuten uitloop ═══════════════════════════════════
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '08:00', '10:00', 'planned', 'bike')
  RETURNING id INTO v_shift2;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id, budgeted_minutes)
  VALUES (v_shift2, v_a, 120);
  INSERT INTO public.shift_declarations (shift_id, courier_id, status, token_hash, token_expires_at,
                                         actual_start, actual_end, claims_travel)
  VALUES (v_shift2, v_courier, 'submitted', public.declaration_hash_token('t-031-kort'),
          now() + INTERVAL '30 days', '08:00', '10:10', false);

  PERFORM public.extra_work_sweep(500);
  IF EXISTS (SELECT 1 FROM public.extra_work WHERE shift_id = v_shift2) THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: tien minuten uitloop leverde een melding op; dan krijgt een apotheek overal mail over.';
  END IF;
  RAISE NOTICE 'GEVAL 1 geslaagd: onder de drempel gebeurt er niets.';

  -- ══ GEVAL 2 en 3: een uur uitloop over twee apotheken ═══════════════
  -- Gepland 2 uur (A 60 + B 60), werkelijk 3 uur → 60 minuten uitloop, 30 elk.
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '13:00', '15:00', 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id, budgeted_minutes)
  VALUES (v_shift, v_a, 60), (v_shift, v_b, 60);
  INSERT INTO public.shift_declarations (shift_id, courier_id, status, token_hash, token_expires_at,
                                         actual_start, actual_end, claims_travel, courier_note)
  VALUES (v_shift, v_courier, 'submitted', public.declaration_hash_token('t-031-lang'),
          now() + INTERVAL '30 days', '13:00', '16:00', false,
          'moest wachten want de assistente was er niet')
  RETURNING id INTO v_dec;

  PERFORM public.extra_work_sweep(500);

  SELECT * INTO v_row FROM public.extra_work WHERE shift_id = v_shift AND pharmacy_id = v_a;
  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: een uur uitloop leverde geen melding op.';
  END IF;
  v_xw := v_row.id;
  IF v_row.status <> 'new' THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: status is %, verwacht new — de sweep mag niet zelf vrijgeven.', v_row.status;
  END IF;
  IF v_row.courier_note IS NULL OR v_row.courier_note NOT LIKE '%assistente%' THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: de toelichting van de koerier is niet meegekopieerd.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.mail_outbox WHERE kind = 'extra_work_request'
               AND payload ->> 'extra_work_id' = v_xw::TEXT) THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: de sweep zette al post klaar. Er mag niets uitgaan vóór de planner vrijgeeft.';
  END IF;
  RAISE NOTICE 'GEVAL 2 geslaagd: melding klaargezet, mét toelichting en zonder mail.';

  IF v_row.share_minutes <> 30 THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: apotheek A krijgt % minuten, verwacht 30 (de helft van een uur uitloop).',
      v_row.share_minutes;
  END IF;
  SELECT id INTO v_xw_b FROM public.extra_work WHERE shift_id = v_shift AND pharmacy_id = v_b;
  IF (SELECT share_minutes FROM public.extra_work WHERE id = v_xw_b) <> 30 THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: apotheek B krijgt niet dezelfde 30 minuten.';
  END IF;
  RAISE NOTICE 'GEVAL 3 geslaagd: de uitloop wordt naar rato verdeeld, elk filiaal ziet zijn eigen deel.';

  -- ══ GEVAL 4: vrijgeven zonder e-mailadres ═══════════════════════════
  BEGIN
    PERFORM public.extra_work_release(v_xw, 'Langer bezig geweest dan gepland.');
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: vrijgeven lukte zonder e-mailadres.';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_msg LIKE 'GEVAL 4 GEFAALD%' THEN RAISE; END IF;
    IF v_state <> '45010' THEN
      RAISE EXCEPTION 'GEVAL 4 GEFAALD: SQLSTATE % (%), verwacht 45010.', v_state, v_msg;
    END IF;
    RAISE NOTICE 'GEVAL 4 geslaagd: zonder adres geen vrijgave (%).', v_msg;
  END;

  -- ══ GEVAL 5: vrijgeven mét adres ════════════════════════════════════
  PERFORM public.set_pharmacy_billing_email(v_a, 'apotheek-a@example.test');
  PERFORM public.extra_work_release(v_xw, 'De rit duurde langer dan gepland.');

  SELECT * INTO v_row FROM public.extra_work WHERE id = v_xw;
  IF v_row.status <> 'released' OR v_row.released_at IS NULL THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: status is % na vrijgeven.', v_row.status;
  END IF;
  IF v_row.planner_note NOT LIKE '%langer dan gepland%' THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: de herschreven toelichting is niet vastgelegd (%).', v_row.planner_note;
  END IF;

  SELECT count(*) INTO v_n FROM public.mail_outbox
   WHERE kind = 'extra_work_request' AND recipient_override = 'apotheek-a@example.test'
     AND courier_id IS NULL AND status = 'pending';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: % outbox-rijen voor de apotheek, verwacht 1.', v_n;
  END IF;
  IF (SELECT count(*) FROM public.mail_pending_direct()
       WHERE recipient = 'apotheek-a@example.test') <> 1 THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: de verzender ziet de post voor de apotheek niet staan.';
  END IF;
  RAISE NOTICE 'GEVAL 5 geslaagd: na vrijgave staat er precies één bericht klaar voor de apotheek.';

  -- ══ GEVAL 6: token, lezen en antwoorden ═════════════════════════════
  SELECT token INTO v_token FROM public.extra_work_issue_token(v_xw);
  IF v_token IS NULL OR length(v_token) < 64 THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: geen bruikbaar token.';
  END IF;
  IF EXISTS (SELECT 1 FROM public.extra_work WHERE id = v_xw AND token_hash = v_token) THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: het token zelf staat in de database.';
  END IF;

  SELECT * INTO v_row FROM public.extra_work_by_token(v_token);
  IF v_row.extra_work_id IS DISTINCT FROM v_xw OR v_row.extra_minutes <> 30 THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: de pagina toont de verkeerde melding of het verkeerde aantal minuten.';
  END IF;
  IF v_row.note NOT LIKE '%langer dan gepland%' THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: de klant krijgt niet de herschreven tekst te zien (%).', v_row.note;
  END IF;

  PERFORM public.extra_work_respond(v_token, true, 'akkoord');
  IF (SELECT status FROM public.extra_work WHERE id = v_xw) <> 'approved' THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: goedkeuren kwam niet aan.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.extra_work_by_token(v_token)) THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: de link doet niets meer na goedkeuring; hij hoort een leesweergave te geven.';
  END IF;
  RAISE NOTICE 'GEVAL 6 geslaagd: de apotheek keurt goed en kan het daarna nog teruglezen.';

  -- ══ GEVAL 7: factuur zolang het bij de klant ligt ═══════════════════
  -- Apotheek B staat nog op 'released'. Werkelijk 90 minuten voor B (helft van
  -- 180), waarvan 30 uitloop → alleen de geplande 60 worden gefactureerd = € 60.
  PERFORM public.set_pharmacy_billing_email(v_b, 'apotheek-b@example.test');
  PERFORM public.extra_work_release(v_xw_b, NULL);

  SELECT * INTO v_row FROM public.invoice_lines(v_b, v_day, v_day) WHERE shift_id = v_shift;
  IF v_row.hours_amount <> 60.00 THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: % gefactureerd, verwacht 60 — de uitloop ligt nog bij de klant.',
      v_row.hours_amount;
  END IF;
  IF v_row.billed_minutes <> 90 THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: billed_minutes is %, verwacht 90 — wat er gewerkt is blijft zichtbaar.',
      v_row.billed_minutes;
  END IF;
  IF NOT v_row.incomplete OR v_row.reason NOT LIKE '%ligt bij de apotheek%' THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: geen markering dat het meerwerk nog openstaat (%).', v_row.reason;
  END IF;
  IF v_row.extra_work_status <> 'released' THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: de meerwerkstatus komt niet mee in de factuurregel.';
  END IF;
  RAISE NOTICE 'GEVAL 7 geslaagd: openstaand meerwerk wordt niet gefactureerd, wel getoond.';

  -- ══ GEVAL 8: factuur na goedkeuring ═════════════════════════════════
  -- Apotheek A: 90 minuten × € 60 = € 90.
  SELECT * INTO v_row FROM public.invoice_lines(v_a, v_day, v_day) WHERE shift_id = v_shift;
  IF v_row.hours_amount <> 90.00 THEN
    RAISE EXCEPTION 'GEVAL 8 GEFAALD: % gefactureerd, verwacht 90 na goedkeuring.', v_row.hours_amount;
  END IF;
  IF v_row.extra_work_status <> 'approved' THEN
    RAISE EXCEPTION 'GEVAL 8 GEFAALD: status % in de factuurregel.', v_row.extra_work_status;
  END IF;
  RAISE NOTICE 'GEVAL 8 geslaagd: goedgekeurd meerwerk wordt volledig gefactureerd.';

  -- ══ GEVAL 9: verlopen ═══════════════════════════════════════════════
  UPDATE public.extra_work SET respond_by = now() - INTERVAL '1 hour' WHERE id = v_xw_b;
  SELECT public.extra_work_expire() INTO v_n;
  IF v_n < 1 OR (SELECT status FROM public.extra_work WHERE id = v_xw_b) <> 'expired' THEN
    RAISE EXCEPTION 'GEVAL 9 GEFAALD: de melding verliep niet na de termijn.';
  END IF;

  SELECT * INTO v_row FROM public.invoice_lines(v_b, v_day, v_day) WHERE shift_id = v_shift;
  IF v_row.hours_amount <> 90.00 THEN
    RAISE EXCEPTION 'GEVAL 9 GEFAALD: % gefactureerd, verwacht 90 — geen reactie is ook factureren.',
      v_row.hours_amount;
  END IF;
  IF v_row.extra_work_status <> 'expired' OR v_row.reason NOT LIKE '%niet beantwoord%' THEN
    RAISE EXCEPTION 'GEVAL 9 GEFAALD: verlopen is niet te onderscheiden van goedgekeurd (status %, reden %).',
      v_row.extra_work_status, v_row.reason;
  END IF;
  RAISE NOTICE 'GEVAL 9 geslaagd: verlopen wordt gefactureerd én apart herkenbaar.';

  -- ══ GEVAL 10: de koerier merkt hier niets van ═══════════════════════
  SELECT computed_reimbursable_km INTO v_before FROM public.shift_declarations WHERE id = v_dec;
  PERFORM public.extra_work_reopen(v_xw);
  PERFORM public.set_pharmacy_billing_email(v_a, 'apotheek-a@example.test');
  PERFORM public.extra_work_release(v_xw, NULL);
  SELECT token INTO v_token FROM public.extra_work_issue_token(v_xw);
  PERFORM public.extra_work_respond(v_token, false, 'niet mee eens');

  SELECT * INTO v_row FROM public.shift_declarations WHERE id = v_dec;
  IF v_row.status <> 'submitted'
     OR v_row.actual_end <> TIME '16:00'
     OR v_row.computed_reimbursable_km IS DISTINCT FROM v_before THEN
    RAISE EXCEPTION 'GEVAL 10 GEFAALD: de declaratie van de koerier is veranderd door een geschil met de klant.';
  END IF;
  RAISE NOTICE 'GEVAL 10 geslaagd: een betwisting raakt de declaratie van de koerier niet.';

  RAISE NOTICE 'ALLE GEVALLEN GESLAAGD.';
END $$;

ROLLBACK;
