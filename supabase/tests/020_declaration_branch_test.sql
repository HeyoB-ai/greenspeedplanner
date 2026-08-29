-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 020: de tak-keuze bij meerdere apotheken
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 020 eerst (of proefdraai 020 met ROLLBACK en daarna dit).
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: één transactie die op ROLLBACK eindigt.
--
-- Opstelling: de standplaats ligt op 25 km, een tweede apotheek op 4 km, en een
-- derde apotheek heeft geen bekende afstand. Drempel 10 km, fiets €0,20 en auto
-- €0,25 per km — eigen tarieven, zodat de test niet afhangt van wat er in
-- reimbursement_rates staat.
--
-- WAT DE TEST DEKT
--   1. Alleen de standplaats            → above_threshold (25 − 10)
--   2. Standplaats + andere apotheek    → other_pharmacy met de VOLLE 25 km
--                                         (vóór 020 was dit 15: de standplaats
--                                          tussen de apotheken won toen)
--   3. Alleen een andere apotheek       → other_pharmacy, ongewijzigd
--   4. Apotheek zonder bekende afstand  → onvolledig mét naam, en GEEN bedrag
--                                         in plaats van een te laag bedrag
--   5. Eigen auto met dezelfde gaten    → opgegeven km's, en niet onvolledig
--   6. Dienst zonder apotheek           → eigen leesbare reden
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
  v_courier UUID;
  v_home    TEXT;
  v_other   TEXT;
  v_third   TEXT;
  v_name3   TEXT;
  v_day     DATE := current_date - 1;
  v_shift   UUID;
  v_c       RECORD;
BEGIN
  -- ── Voorbereiding ────────────────────────────────────────────────────
  SELECT id INTO v_courier FROM public.user_profiles WHERE role = 'courier' ORDER BY id LIMIT 1;
  IF v_courier IS NULL THEN RAISE EXCEPTION 'OPZET: geen koerier in user_profiles.'; END IF;

  SELECT id INTO v_home  FROM public.pharmacies ORDER BY id LIMIT 1;
  SELECT id INTO v_other FROM public.pharmacies WHERE id <> v_home ORDER BY id LIMIT 1;
  SELECT id, name INTO v_third, v_name3
    FROM public.pharmacies WHERE id NOT IN (v_home, v_other) ORDER BY id LIMIT 1;
  IF v_other IS NULL THEN RAISE EXCEPTION 'OPZET: er zijn minder dan twee apotheken.'; END IF;
  -- Zonder naam valt de LIKE hieronder op NULL uit en zou de test stilletjes
  -- slagen; dan vergelijken we op het id, precies zoals de functie het meldt.
  v_name3 := COALESCE(v_name3, v_third);

  INSERT INTO public.reimbursement_rates (transport_mode, rate_per_km, threshold_km, effective_from, note)
  VALUES ('bike', 0.2000, 10, v_day, 'test 020'), ('car', 0.2500, 10, v_day, 'test 020')
  ON CONFLICT (transport_mode, effective_from) DO UPDATE
    SET rate_per_km = EXCLUDED.rate_per_km, threshold_km = EXCLUDED.threshold_km;

  UPDATE public.user_profiles SET home_pharmacy_id = v_home WHERE id = v_courier;

  -- Standplaats op 25 km, de tweede apotheek op 4. De derde krijgt bewust GEEN
  -- rij: dat is het geval waar deze migratie om draait.
  INSERT INTO public.courier_distances (courier_id, pharmacy_id, distance_km, source)
  VALUES (v_courier, v_home, 25.00, 'manual'), (v_courier, v_other, 4.00, 'manual')
  ON CONFLICT (courier_id, pharmacy_id) DO UPDATE
    SET distance_km = EXCLUDED.distance_km, source = 'manual';
  DELETE FROM public.courier_distances
   WHERE courier_id = v_courier AND pharmacy_id = v_third;

  -- ── GEVAL 1: alleen de standplaats ───────────────────────────────────
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '05:00', '07:00', 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id) VALUES (v_shift, v_home);

  SELECT * INTO v_c FROM public.declaration_compute(v_shift);
  IF v_c.rule <> 'above_threshold' OR v_c.reimbursable_km <> 15.00 THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: regel % met % km, verwacht above_threshold met 15.', v_c.rule, v_c.reimbursable_km;
  END IF;
  RAISE NOTICE 'GEVAL 1 geslaagd: een dienst die alleen op de standplaats is, houdt de drempelregel.';

  -- ── GEVAL 2: standplaats ÉN een andere apotheek ──────────────────────
  -- Dit is de verandering van migratie 020. Vóór deze migratie won de
  -- standplaats zodra hij ertussen zat en kwam hier 15 uit.
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '08:00', '12:00', 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id)
  VALUES (v_shift, v_home), (v_shift, v_other);

  SELECT * INTO v_c FROM public.declaration_compute(v_shift);
  IF v_c.rule <> 'other_pharmacy' THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: regel is %, verwacht other_pharmacy — één andere apotheek is genoeg.', v_c.rule;
  END IF;
  IF v_c.reimbursable_km <> 25.00 THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: % km vergoed, verwacht de volle 25 (de verste apotheek, drempel vervalt).', v_c.reimbursable_km;
  END IF;
  IF v_c.pharmacy_id <> v_home THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: bestemming is %, verwacht de verste apotheek.', v_c.pharmacy_id;
  END IF;
  IF v_c.incomplete THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: alle afstanden zijn bekend, toch onvolledig (reden: %).', v_c.reason;
  END IF;
  RAISE NOTICE 'GEVAL 2 geslaagd: één andere apotheek erbij maakt er other_pharmacy van, met de volle afstand.';

  -- ── GEVAL 3: alleen een andere apotheek (ongewijzigd gedrag) ─────────
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '13:00', '15:00', 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id) VALUES (v_shift, v_other);

  SELECT * INTO v_c FROM public.declaration_compute(v_shift);
  IF v_c.rule <> 'other_pharmacy' OR v_c.reimbursable_km <> 4.00 THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: regel % met % km, verwacht other_pharmacy met 4.', v_c.rule, v_c.reimbursable_km;
  END IF;
  RAISE NOTICE 'GEVAL 3 geslaagd: een dienst buiten de standplaats blijft de volledige afstand houden.';

  -- ── GEVAL 4: een apotheek zonder bekende afstand ─────────────────────
  IF v_third IS NOT NULL THEN
    INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                               status, transport_mode)
    VALUES (v_courier, 'regular', v_day, '16:00', '18:00', 'planned', 'bike')
    RETURNING id INTO v_shift;
    INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id)
    VALUES (v_shift, v_other), (v_shift, v_third);

    SELECT * INTO v_c FROM public.declaration_compute(v_shift);
    IF v_c.rule <> 'other_pharmacy' THEN
      RAISE EXCEPTION 'GEVAL 4 GEFAALD: regel is %, verwacht other_pharmacy.', v_c.rule;
    END IF;
    IF v_c.reimbursable_km IS NOT NULL THEN
      RAISE EXCEPTION 'GEVAL 4 GEFAALD: % km vergoed terwijl een afstand ontbreekt — dat is een ondergrens, geen maximum.', v_c.reimbursable_km;
    END IF;
    IF NOT v_c.incomplete OR v_c.reason NOT LIKE '%' || v_name3 || '%' THEN
      RAISE EXCEPTION 'GEVAL 4 GEFAALD: de ontbrekende apotheek wordt niet bij naam gemeld (reden: %).', v_c.reason;
    END IF;
    RAISE NOTICE 'GEVAL 4 geslaagd: een ontbrekende afstand levert onbekend op, met de apotheek erbij, in plaats van een te laag bedrag.';

    -- ── GEVAL 5: dezelfde gaten, maar met een eigen auto ───────────────
    -- Daar komt het bedrag van de koerier; de ontbrekende afstand raakt alleen
    -- de referentie en mag de rij dus niet onvolledig maken.
    INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                               status, transport_mode, car_is_own)
    VALUES (v_courier, 'regular', v_day, '19:00', '21:00', 'planned', 'car', true)
    RETURNING id INTO v_shift;
    INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id)
    VALUES (v_shift, v_home), (v_shift, v_third);

    SELECT * INTO v_c FROM public.declaration_compute(v_shift, 42.0);
    IF v_c.rule <> 'own_car' OR v_c.reimbursable_km <> 42.0 THEN
      RAISE EXCEPTION 'GEVAL 5 GEFAALD: regel % met % km, verwacht own_car met 42.', v_c.rule, v_c.reimbursable_km;
    END IF;
    IF v_c.incomplete THEN
      RAISE EXCEPTION 'GEVAL 5 GEFAALD: eigen auto is onvolledig gemarkeerd op een ontbrekende referentieafstand (reden: %).', v_c.reason;
    END IF;
    RAISE NOTICE 'GEVAL 5 geslaagd: bij eigen auto raakt een ontbrekende afstand alleen de referentie.';
  ELSE
    RAISE WARNING 'GEVAL 4 EN 5 OVERGESLAGEN: er is geen derde apotheek om een ontbrekende afstand mee te maken.';
  END IF;

  -- ── GEVAL 6: een dienst zonder apotheek ──────────────────────────────
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'other_transport', v_day, '22:00', '23:00', 'planned', 'bike')
  RETURNING id INTO v_shift;

  SELECT * INTO v_c FROM public.declaration_compute(v_shift);
  IF NOT v_c.incomplete OR v_c.reason NOT LIKE '%geen apotheek%' THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: een dienst zonder apotheek hoort een eigen reden te krijgen (reden: %).', v_c.reason;
  END IF;
  IF v_c.reimbursable_km IS NOT NULL THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: er is % km vergoed zonder dat er een apotheek in de dienst zit.', v_c.reimbursable_km;
  END IF;
  RAISE NOTICE 'GEVAL 6 geslaagd: een dienst zonder apotheek zegt dat ook zo.';

  RAISE NOTICE 'ALLE GEVALLEN GESLAAGD.';
END $$;

ROLLBACK;
