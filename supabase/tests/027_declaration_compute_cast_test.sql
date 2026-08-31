-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 027: de drie takken met een vaste zin
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 027 eerst (of proefdraai 027 met ROLLBACK en daarna dit).
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: één transactie die op ROLLBACK eindigt. De standplaats
-- van de gebruikte koerier wordt onderweg gewijzigd en draait mee terug.
--
-- WAT DE TEST DEKT
--   Alle drie de takken die een vaste zin aan de redenen toevoegen. Vóór de cast
--   liepen die stuk op "malformed array literal"; ze moeten nu gewoon een reden
--   teruggeven. De uitkomsten zelf horen ONGEWIJZIGD te zijn — 027 is alleen een
--   cast — dus de test controleert ook de regel en het aantal kilometers.
--
--   1. Koerier zonder standplaats  → terugval op de drempelregel, gemarkeerd
--   2. Onbekende afstand           → geen vergoeding, gemarkeerd
--   3. Dienst zonder apotheek      → gemarkeerd met een eigen reden
--   4. Gewone berekening           → onveranderd (regressie)
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
  v_courier UUID;
  v_home    TEXT;
  v_other   TEXT;
  v_day     DATE := current_date - 1;
  v_shift   UUID;
  v_c       RECORD;
BEGIN
  SELECT id INTO v_courier FROM public.user_profiles WHERE role = 'courier' ORDER BY id LIMIT 1;
  IF v_courier IS NULL THEN RAISE EXCEPTION 'OPZET: geen koerier in user_profiles.'; END IF;
  SELECT id INTO v_home  FROM public.pharmacies ORDER BY id LIMIT 1;
  SELECT id INTO v_other FROM public.pharmacies WHERE id <> v_home ORDER BY id LIMIT 1;
  IF v_home IS NULL THEN RAISE EXCEPTION 'OPZET: geen apotheek in pharmacies.'; END IF;

  -- Eigen tarief met drempel 10, zodat de uitkomsten niet afhangen van wat er in
  -- reimbursement_rates staat.
  INSERT INTO public.reimbursement_rates (transport_mode, rate_per_km, threshold_km, effective_from, note)
  VALUES ('bike', 0.2000, 10, v_day, 'test 027')
  ON CONFLICT (transport_mode, effective_from) DO UPDATE
    SET rate_per_km = EXCLUDED.rate_per_km, threshold_km = EXCLUDED.threshold_km;

  UPDATE public.user_profiles SET home_pharmacy_id = v_home WHERE id = v_courier;
  INSERT INTO public.courier_distances (courier_id, pharmacy_id, distance_km, source)
  VALUES (v_courier, v_home, 25.00, 'manual')
  ON CONFLICT (courier_id, pharmacy_id) DO UPDATE
    SET distance_km = 25.00, source = 'manual';

  -- Eén dienst op de standplaats; die hergebruiken we voor geval 1, 2 en 4.
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '08:00', '12:00', 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id) VALUES (v_shift, v_home);

  -- ══ GEVAL 4 eerst: de gewone berekening als ijkpunt ═════════════════
  SELECT * INTO v_c FROM public.declaration_compute(v_shift);
  IF v_c.rule <> 'above_threshold' OR v_c.reimbursable_km <> 15.00 OR v_c.incomplete THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: regel % met % km (gemarkeerd: %), verwacht above_threshold met 15 en niet gemarkeerd.',
      v_c.rule, v_c.reimbursable_km, v_c.incomplete;
  END IF;
  RAISE NOTICE 'GEVAL 4 geslaagd: de gewone berekening is onveranderd.';

  -- ══ GEVAL 1: koerier zonder standplaats ═════════════════════════════
  UPDATE public.user_profiles SET home_pharmacy_id = NULL WHERE id = v_courier;

  SELECT * INTO v_c FROM public.declaration_compute(v_shift);
  IF NOT v_c.incomplete OR v_c.reason NOT LIKE '%standplaats%' THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: geen reden over de standplaats teruggekregen (incomplete=%, reason=%).',
      v_c.incomplete, v_c.reason;
  END IF;
  IF v_c.rule <> 'above_threshold' OR v_c.reimbursable_km <> 15.00 THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: uitkomst veranderd — regel % met % km, verwacht above_threshold met 15.',
      v_c.rule, v_c.reimbursable_km;
  END IF;
  RAISE NOTICE 'GEVAL 1 geslaagd: zonder standplaats komt de reden terug (%).', v_c.reason;

  UPDATE public.user_profiles SET home_pharmacy_id = v_home WHERE id = v_courier;

  -- ══ GEVAL 2: onbekende afstand ══════════════════════════════════════
  -- De standplaats is de enige apotheek van de dienst, maar er is geen afstand.
  DELETE FROM public.courier_distances
   WHERE courier_id = v_courier AND pharmacy_id = v_home;

  SELECT * INTO v_c FROM public.declaration_compute(v_shift);
  IF NOT v_c.incomplete OR v_c.reason NOT LIKE '%geen afstand bekend voor deze koerier en apotheek%' THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: geen reden over de ontbrekende afstand (incomplete=%, reason=%).',
      v_c.incomplete, v_c.reason;
  END IF;
  IF v_c.reimbursable_km IS NOT NULL THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: uitkomst veranderd — % km terwijl de afstand onbekend is.', v_c.reimbursable_km;
  END IF;
  RAISE NOTICE 'GEVAL 2 geslaagd: een onbekende afstand komt terug als reden (%).', v_c.reason;

  -- ══ GEVAL 3: dienst zonder apotheek ═════════════════════════════════
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'other_transport', v_day, '14:00', '15:00', 'planned', 'bike')
  RETURNING id INTO v_shift;

  SELECT * INTO v_c FROM public.declaration_compute(v_shift);
  IF NOT v_c.incomplete OR v_c.reason NOT LIKE '%geen apotheek%' THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: geen reden over de ontbrekende apotheek (incomplete=%, reason=%).',
      v_c.incomplete, v_c.reason;
  END IF;
  RAISE NOTICE 'GEVAL 3 geslaagd: een dienst zonder apotheek komt terug als reden (%).', v_c.reason;

  RAISE NOTICE 'ALLE GEVALLEN GESLAAGD.';
END $$;

ROLLBACK;
