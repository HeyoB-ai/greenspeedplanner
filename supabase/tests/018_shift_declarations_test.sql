-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 018: de rekenregel voor reiskosten
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 018 eerst (of proefdraai 018 met ROLLBACK en daarna dit).
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: één transactie die op ROLLBACK eindigt. Ook de
-- standplaats van de gebruikte koerier en de tijdelijke tarieven verdwijnen weer.
--
-- De test zet zijn eigen tarief met een ingangsdatum van gisteren, zodat hij niet
-- afhangt van wat er in reimbursement_rates staat: drempel 10 km, €0,25 per km
-- voor de auto en €0,20 voor de fiets.
--
-- WAT DE TEST DEKT — de vier takken van de regel, plus de randen
--   1. own_car          — eigen auto: opgegeven km's, drempel vervalt
--   2. own_car          — óók bij een korte afstand: geen drempel, geen aftrek
--   3. other_pharmacy   — andere apotheek: volledige afstand, ook onder de drempel
--   4. above_threshold  — standplaats: afstand min drempel
--   5. none             — standplaats onder de drempel: nul, en niet onbekend
--   6. geen standplaats — terugval op de drempelregel én onvolledig gemarkeerd
--   7. geen afstand     — onbekend blijft onbekend (NULL), nooit stilzwijgend 0
--   8. tarief per datum — een oude dienst rekent met het oude tarief
--   9. meerdere apotheken — de standplaats wint als bestemming
--  10. own_car_km       — mag niet bij een fietsdienst (trigger)
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
  v_courier UUID;
  v_home    TEXT;
  v_other   TEXT;
  v_third   TEXT;
  v_day     DATE := current_date - 1;
  v_old     DATE := current_date - 400;
  v_shift   UUID;
  v_dec     UUID;
  v_c       RECORD;
  v_msg     TEXT;
BEGIN
  -- ── Voorbereiding ────────────────────────────────────────────────────
  SELECT id INTO v_courier FROM public.user_profiles WHERE role = 'courier' ORDER BY id LIMIT 1;
  IF v_courier IS NULL THEN RAISE EXCEPTION 'OPZET: geen koerier in user_profiles.'; END IF;

  SELECT id INTO v_home  FROM public.pharmacies ORDER BY id LIMIT 1;
  SELECT id INTO v_other FROM public.pharmacies WHERE id <> v_home ORDER BY id LIMIT 1;
  SELECT id INTO v_third FROM public.pharmacies WHERE id NOT IN (v_home, v_other) ORDER BY id LIMIT 1;
  IF v_other IS NULL THEN RAISE EXCEPTION 'OPZET: er zijn minder dan twee apotheken.'; END IF;

  -- Eigen tarieven, jonger dan wat er staat, zodat de test niet afhangt van de
  -- productiewaarden. Drempel 10 km.
  INSERT INTO public.reimbursement_rates (transport_mode, rate_per_km, threshold_km, effective_from, note)
  VALUES ('car', 0.2500, 10, v_day, 'test 018'), ('bike', 0.2000, 10, v_day, 'test 018')
  ON CONFLICT (transport_mode, effective_from) DO UPDATE
    SET rate_per_km = EXCLUDED.rate_per_km, threshold_km = EXCLUDED.threshold_km;

  -- Standplaats en afstanden: thuis → standplaats 25 km, thuis → andere 4 km.
  UPDATE public.user_profiles SET home_pharmacy_id = v_home WHERE id = v_courier;

  INSERT INTO public.courier_distances (courier_id, pharmacy_id, distance_km, source)
  VALUES (v_courier, v_home, 25.00, 'manual'), (v_courier, v_other, 4.00, 'manual')
  ON CONFLICT (courier_id, pharmacy_id) DO UPDATE
    SET distance_km = EXCLUDED.distance_km, source = 'manual';

  -- ── GEVAL 1: eigen auto, standplaats op 25 km ────────────────────────
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode, car_is_own)
  VALUES (v_courier, 'regular', v_day, '08:00', '12:00', 'planned', 'car', true)
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id) VALUES (v_shift, v_home);

  SELECT * INTO v_c FROM public.declaration_compute(v_shift, 42.0);
  IF v_c.rule <> 'own_car' THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: regel is %, verwacht own_car.', v_c.rule;
  END IF;
  IF v_c.reimbursable_km <> 42.0 THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: % km vergoed, verwacht 42 — de drempel is toegepast terwijl die bij eigen auto vervalt.', v_c.reimbursable_km;
  END IF;
  IF v_c.distance_km <> 25.00 THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: referentieafstand is %, verwacht 25.', v_c.distance_km;
  END IF;
  RAISE NOTICE 'GEVAL 1 geslaagd: eigen auto krijgt de opgegeven km''s, met de berekende afstand ernaast.';

  -- ── GEVAL 2: eigen auto, maar de dienst is bij de apotheek op 4 km ───
  -- Ook onder de drempel én bij een andere apotheek blijft het own_car: die tak
  -- gaat voor, en er wordt niets afgetrokken.
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode, car_is_own)
  VALUES (v_courier, 'regular', v_day, '13:00', '15:00', 'planned', 'car', true)
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id) VALUES (v_shift, v_other);

  SELECT * INTO v_c FROM public.declaration_compute(v_shift, 9.0);
  IF v_c.rule <> 'own_car' OR v_c.reimbursable_km <> 9.0 THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: regel % met % km, verwacht own_car met 9.', v_c.rule, v_c.reimbursable_km;
  END IF;
  RAISE NOTICE 'GEVAL 2 geslaagd: eigen auto gaat voor op de andere takken, ook bij een korte rit.';

  -- ── GEVAL 3: fiets naar een ANDERE apotheek (4 km) ───────────────────
  -- Volledige afstand, ook al is die kleiner dan de drempel. Dit is de
  -- tegenintuïtieve regel uit het ontwerp en is zo bevestigd.
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '16:00', '18:00', 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id) VALUES (v_shift, v_other);

  SELECT * INTO v_c FROM public.declaration_compute(v_shift);
  IF v_c.rule <> 'other_pharmacy' THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: regel is %, verwacht other_pharmacy.', v_c.rule;
  END IF;
  IF v_c.reimbursable_km <> 4.00 THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: % km vergoed, verwacht 4 — de drempel hoort bij een andere apotheek te vervallen.', v_c.reimbursable_km;
  END IF;
  RAISE NOTICE 'GEVAL 3 geslaagd: andere apotheek dan de standplaats levert de volledige afstand op.';

  -- ── GEVAL 4: fiets naar de STANDPLAATS (25 km) ───────────────────────
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '05:00', '07:00', 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id) VALUES (v_shift, v_home);

  SELECT * INTO v_c FROM public.declaration_compute(v_shift);
  IF v_c.rule <> 'above_threshold' OR v_c.reimbursable_km <> 15.00 THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: regel % met % km, verwacht above_threshold met 15 (25 − 10).', v_c.rule, v_c.reimbursable_km;
  END IF;
  RAISE NOTICE 'GEVAL 4 geslaagd: naar de standplaats geldt afstand min drempel.';

  -- ── GEVAL 5: standplaats ONDER de drempel → nul, niet onbekend ───────
  UPDATE public.courier_distances SET distance_km = 6.00
   WHERE courier_id = v_courier AND pharmacy_id = v_home;

  SELECT * INTO v_c FROM public.declaration_compute(v_shift);
  IF v_c.rule <> 'none' THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: regel is %, verwacht none.', v_c.rule;
  END IF;
  IF v_c.reimbursable_km IS NULL OR v_c.reimbursable_km <> 0 THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: vergoeding is %, verwacht 0 (en nadrukkelijk niet NULL).', v_c.reimbursable_km;
  END IF;
  IF v_c.incomplete THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: een terechte nul is niet onvolledig (reden: %).', v_c.reason;
  END IF;
  RAISE NOTICE 'GEVAL 5 geslaagd: onder de drempel is de uitkomst 0 en volledig.';

  UPDATE public.courier_distances SET distance_km = 25.00
   WHERE courier_id = v_courier AND pharmacy_id = v_home;

  -- ── GEVAL 6: geen standplaats → drempelregel + onvolledig ────────────
  UPDATE public.user_profiles SET home_pharmacy_id = NULL WHERE id = v_courier;

  SELECT * INTO v_c FROM public.declaration_compute(v_shift);
  IF v_c.rule <> 'above_threshold' OR v_c.reimbursable_km <> 15.00 THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: regel % met % km, verwacht de terugval above_threshold met 15.', v_c.rule, v_c.reimbursable_km;
  END IF;
  IF NOT v_c.incomplete OR v_c.reason NOT LIKE '%standplaats%' THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: zonder standplaats hoort de declaratie onvolledig te zijn (incomplete=%, reden=%).', v_c.incomplete, v_c.reason;
  END IF;
  RAISE NOTICE 'GEVAL 6 geslaagd: zonder standplaats wordt er teruggevallen én gemarkeerd.';

  UPDATE public.user_profiles SET home_pharmacy_id = v_home WHERE id = v_courier;

  -- ── GEVAL 7: geen afstand bekend → NULL, nooit 0 ─────────────────────
  IF v_third IS NOT NULL THEN
    INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                               status, transport_mode)
    VALUES (v_courier, 'regular', v_day, '19:00', '21:00', 'planned', 'bike')
    RETURNING id INTO v_shift;
    INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id) VALUES (v_shift, v_third);

    SELECT * INTO v_c FROM public.declaration_compute(v_shift);
    IF v_c.reimbursable_km IS NOT NULL THEN
      RAISE EXCEPTION 'GEVAL 7 GEFAALD: zonder bekende afstand is de uitkomst %, verwacht NULL.', v_c.reimbursable_km;
    END IF;
    IF NOT v_c.incomplete OR v_c.reason NOT LIKE '%afstand%' THEN
      RAISE EXCEPTION 'GEVAL 7 GEFAALD: ontbrekende afstand is niet gemarkeerd (reden: %).', v_c.reason;
    END IF;
    RAISE NOTICE 'GEVAL 7 geslaagd: een onbekende afstand blijft onbekend en wordt gemeld.';
  ELSE
    RAISE WARNING 'GEVAL 7 OVERGESLAGEN: er is geen derde apotheek om een onbekende afstand mee te maken.';
  END IF;

  -- ── GEVAL 8: het tarief van de dienstdatum, niet het nieuwste ────────
  INSERT INTO public.reimbursement_rates (transport_mode, rate_per_km, threshold_km, effective_from, note)
  VALUES ('bike', 0.1900, 25, v_old, 'test 018 — oud tarief, hogere drempel')
  ON CONFLICT (transport_mode, effective_from) DO UPDATE
    SET rate_per_km = EXCLUDED.rate_per_km, threshold_km = EXCLUDED.threshold_km;

  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_old, '08:00', '10:00', 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id) VALUES (v_shift, v_home);

  SELECT * INTO v_c FROM public.declaration_compute(v_shift);
  IF (SELECT rate_per_km FROM public.reimbursement_rates WHERE id = v_c.rate_id) <> 0.1900 THEN
    RAISE EXCEPTION 'GEVAL 8 GEFAALD: er is niet met het tarief van de dienstdatum gerekend.';
  END IF;
  IF v_c.reimbursable_km <> 0 OR v_c.rule <> 'none' THEN
    RAISE EXCEPTION 'GEVAL 8 GEFAALD: met drempel 25 hoort 25 km op 0 uit te komen, kreeg % (%).', v_c.reimbursable_km, v_c.rule;
  END IF;
  RAISE NOTICE 'GEVAL 8 geslaagd: een oude dienst rekent met het tarief én de drempel van toen.';

  -- ── GEVAL 9: dienst over twee apotheken — de standplaats wint ────────
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '09:30', '11:30', 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id)
  VALUES (v_shift, v_home), (v_shift, v_other);

  SELECT * INTO v_c FROM public.declaration_compute(v_shift);
  IF v_c.pharmacy_id <> v_home OR v_c.rule <> 'above_threshold' THEN
    RAISE EXCEPTION 'GEVAL 9 GEFAALD: bestemming % met regel %, verwacht de standplaats met above_threshold.', v_c.pharmacy_id, v_c.rule;
  END IF;
  RAISE NOTICE 'GEVAL 9 geslaagd: staat de standplaats tussen de apotheken, dan is dat de bestemming.';

  -- ── GEVAL 10: km's bij een fietsdienst worden geweigerd ──────────────
  -- v_shift is hier de fietsdienst uit geval 9.
  INSERT INTO public.shift_declarations (shift_id, courier_id, token_hash, token_expires_at)
  VALUES (v_shift, v_courier, public.declaration_hash_token('test-token-018'), now() + INTERVAL '30 days')
  RETURNING id INTO v_dec;

  BEGIN
    UPDATE public.shift_declarations SET own_car_km = 30 WHERE id = v_dec;
    RAISE EXCEPTION 'GEVAL 10 GEFAALD: kilometers werden geaccepteerd op een fietsdienst.';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg LIKE 'GEVAL 10 GEFAALD%' THEN RAISE; END IF;
    RAISE NOTICE 'GEVAL 10 geslaagd: de trigger weigert km''s bij een dienst zonder eigen auto.';
  END;

  RAISE NOTICE 'ALLE GEVALLEN GESLAAGD.';
END $$;

ROLLBACK;
