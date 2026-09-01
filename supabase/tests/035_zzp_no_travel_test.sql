-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 035: geen kilometervergoeding voor zzp'ers
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 035 eerst (of proefdraai 035 met ROLLBACK en daarna dit).
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: één transactie die op ROLLBACK eindigt. De
-- contractvorm van de gebruikte koerier wordt onderweg gewijzigd en draait
-- gewoon mee terug.
--
-- OPSTELLING — standplaats op 25 km, een tweede apotheek zonder bekende
-- afstand, drempel 10 km. Eigen tarieven, zodat de test niet afhangt van wat er
-- in reimbursement_rates staat.
--
-- De contractvorm wordt gezet waar hij te zetten is: in employees zodra
-- migratie 029 gedraaid is, anders in user_profiles.employmentType. Bestaat
-- geen van beide, dan stopt de test met een leesbare opzetfout — dan is er in
-- deze database namelijk niets om een zzp'er aan te herkennen, en dat is iets
-- om te weten in plaats van omheen te testen.
--
-- WAT DE TEST DEKT
--   1. Loondienst              → de vierdelige regel is onveranderd (25 − 10)
--   2. Dezelfde dienst als zzp → rule 'zzp', geen km, geen tarief
--   3. Zzp met een ontbrekende afstand → nog steeds niet onvolledig
--   4. Zzp met eigen auto      → de own_car-tak wint niet meer
--   5. declaration_recompute() slaat 'zzp' op (de CHECK laat het toe)
--   6. declaration_by_token() geeft is_contractor terug
--   7. invoice_lines() belast geen reiskosten door voor een zzp'er
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- Zet de contractvorm op de plek die er in deze database is, en meld welke dat
-- was. Dynamisch, want beide bronnen kunnen ontbreken: employees bestaat pas na
-- migratie 029, en employmentType is een kolom van de bezorg-app die hier niet
-- te verifiëren is.
CREATE OR REPLACE FUNCTION public.test_035_set_employment(p_courier UUID, p_type TEXT)
RETURNS TEXT
LANGUAGE plpgsql AS $helper$
DECLARE v_has BOOLEAN;
BEGIN
  IF to_regclass('public.employees') IS NOT NULL THEN
    EXECUTE $q$
      INSERT INTO public.employees (first_name, last_name, employment_type, user_profile_id)
      VALUES ('Test', 'Koerier 035', $1, $2)
      ON CONFLICT (user_profile_id) DO UPDATE SET employment_type = EXCLUDED.employment_type
    $q$ USING p_type, p_courier;
    RETURN 'employees';
  END IF;

  SELECT to_jsonb(up) ? 'employmentType' INTO v_has
  FROM public.user_profiles up WHERE up.id = p_courier;

  IF v_has THEN
    EXECUTE 'UPDATE public.user_profiles SET "employmentType" = $1 WHERE id = $2'
      USING p_type, p_courier;
    RETURN 'user_profiles';
  END IF;

  RAISE EXCEPTION 'OPZET: er is geen plek om een contractvorm vast te leggen — employees bestaat niet (migratie 029) en user_profiles heeft geen kolom employmentType. Zolang dat zo is, herkent declaration_is_contractor() niemand als zzp''er en doet migratie 035 niets.';
END;
$helper$;

DO $$
DECLARE
  v_planner UUID;
  v_courier UUID;
  v_via     TEXT;
  v_home    TEXT;
  v_other   TEXT;
  v_day     DATE := current_date - 3;
  v_shift   UUID;
  v_car     UUID;
  v_dec     UUID;
  v_c       RECORD;
  v_row     RECORD;
  v_token   TEXT := 't-035-token';
BEGIN
  -- ── Voorbereiding ────────────────────────────────────────────────────
  SELECT id INTO v_planner FROM public.user_profiles
   WHERE role IN ('superuser','supervisor','admin') ORDER BY id LIMIT 1;
  IF v_planner IS NULL THEN RAISE EXCEPTION 'OPZET: geen planner in user_profiles.'; END IF;

  SELECT id INTO v_courier FROM public.user_profiles WHERE role = 'courier' ORDER BY id LIMIT 1;
  IF v_courier IS NULL THEN RAISE EXCEPTION 'OPZET: geen koerier in user_profiles.'; END IF;

  SELECT id INTO v_home  FROM public.pharmacies ORDER BY id LIMIT 1;
  SELECT id INTO v_other FROM public.pharmacies WHERE id <> v_home ORDER BY id LIMIT 1;
  IF v_other IS NULL THEN RAISE EXCEPTION 'OPZET: er zijn minder dan twee apotheken.'; END IF;

  PERFORM set_config('request.jwt.claim.sub', v_planner::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_planner, 'role', 'authenticated')::text, true);

  INSERT INTO public.reimbursement_rates (transport_mode, rate_per_km, threshold_km, effective_from, note)
  VALUES ('bike', 0.2000, 10, v_day, 'test 035'), ('car', 0.2500, 10, v_day, 'test 035')
  ON CONFLICT (transport_mode, effective_from) DO UPDATE
    SET rate_per_km = EXCLUDED.rate_per_km, threshold_km = EXCLUDED.threshold_km;

  UPDATE public.user_profiles SET home_pharmacy_id = v_home WHERE id = v_courier;

  INSERT INTO public.courier_distances (courier_id, pharmacy_id, distance_km, source)
  VALUES (v_courier, v_home, 25.00, 'manual')
  ON CONFLICT (courier_id, pharmacy_id) DO UPDATE
    SET distance_km = EXCLUDED.distance_km, source = 'manual';
  -- De tweede apotheek krijgt bewust GEEN afstand: dat is het geval dat bij
  -- loondienst een markering oplevert en bij zzp niets hoort op te leveren.
  DELETE FROM public.courier_distances
   WHERE courier_id = v_courier AND pharmacy_id = v_other;

  v_via := public.test_035_set_employment(v_courier, 'loondienst');
  RAISE NOTICE 'Contractvorm wordt vastgelegd in %.', v_via;

  -- ══ GEVAL 1: loondienst — de bestaande regel ════════════════════════
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time,
                             budgeted_end_time, status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '05:00', '07:00', 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id, budgeted_minutes)
  VALUES (v_shift, v_home, 120);

  SELECT * INTO v_c FROM public.declaration_compute(v_shift);
  IF v_c.rule <> 'above_threshold' OR v_c.reimbursable_km <> 15.00 THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: regel % met % km, verwacht above_threshold met 15. De vier bestaande takken horen ongemoeid te blijven.',
      v_c.rule, v_c.reimbursable_km;
  END IF;
  RAISE NOTICE 'GEVAL 1 geslaagd: bij loondienst verandert er niets.';

  -- ══ GEVAL 2: dezelfde dienst, nu als zzp'er ═════════════════════════
  PERFORM public.test_035_set_employment(v_courier, 'zzp');

  SELECT * INTO v_c FROM public.declaration_compute(v_shift);
  IF v_c.rule <> 'zzp' THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: regel %, verwacht zzp. De nieuwe tak hoort vóór de vier andere te komen.', v_c.rule;
  END IF;
  IF v_c.reimbursable_km IS NOT NULL THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: % vergoedbare km bij een zzp''er; verwacht niets.', v_c.reimbursable_km;
  END IF;
  IF v_c.rate_id IS NOT NULL THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: er hangt een tarief aan de rij; zonder recht op vergoeding hoort daar niets te staan.';
  END IF;
  IF v_c.incomplete THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: gemarkeerd als onvolledig (%). Bij een zzp''er hoort er niets te staan, en dat is geen gebrek.', v_c.reason;
  END IF;
  IF v_c.distance_km <> 25.00 THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: referentieafstand %, verwacht 25 — die mag als informatie blijven staan.', v_c.distance_km;
  END IF;
  RAISE NOTICE 'GEVAL 2 geslaagd: geen vergoeding, geen tarief, geen markering, wel de referentieafstand.';

  -- ══ GEVAL 3: zzp met een apotheek zonder bekende afstand ════════════
  -- Bij loondienst levert dit "geen afstand bekend voor: …" op. Bij zzp wordt
  -- er niets uitgerekend, dus hoort die melding er ook niet te staan.
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id, budgeted_minutes)
  VALUES (v_shift, v_other, 60);

  SELECT * INTO v_c FROM public.declaration_compute(v_shift);
  IF v_c.rule <> 'zzp' OR v_c.incomplete THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: regel % en onvolledig=% (%). Een ontbrekende afstand raakt een berekening die hier niet plaatsvindt.',
      v_c.rule, v_c.incomplete, v_c.reason;
  END IF;
  RAISE NOTICE 'GEVAL 3 geslaagd: ontbrekende afstanden leveren bij een zzp''er geen markering op.';

  -- ══ GEVAL 4: zzp met eigen auto ═════════════════════════════════════
  -- De own_car-tak stond eerst; zonder de nieuwe volgorde zou een zzp'er via
  -- die tak alsnog zijn opgegeven kilometers vergoed krijgen.
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time,
                             budgeted_end_time, status, transport_mode, car_is_own)
  VALUES (v_courier, 'regular', v_day, '09:00', '12:00', 'planned', 'car', true)
  RETURNING id INTO v_car;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id, budgeted_minutes)
  VALUES (v_car, v_home, 180);

  SELECT * INTO v_c FROM public.declaration_compute(v_car, 40);
  IF v_c.rule <> 'zzp' OR v_c.reimbursable_km IS NOT NULL THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: regel % met % km. Eigen auto mag de zzp-tak niet omzeilen.',
      v_c.rule, v_c.reimbursable_km;
  END IF;
  RAISE NOTICE 'GEVAL 4 geslaagd: ook met eigen auto krijgt een zzp''er geen kilometervergoeding.';

  -- ══ GEVAL 5: de uitkomst is op te slaan ═════════════════════════════
  -- De CHECK op computed_rule kende 'zzp' niet; zonder stap 1 van de migratie
  -- klapt elke herberekening hier.
  INSERT INTO public.shift_declarations (
    shift_id, courier_id, status, token_hash, token_expires_at,
    actual_start, actual_end, claims_travel, own_car_km)
  VALUES (v_car, v_courier, 'submitted',
          public.declaration_hash_token(v_token), now() + INTERVAL '30 days',
          '09:00', '12:00', true, 40)
  RETURNING id INTO v_dec;

  PERFORM public.declaration_recompute(v_dec);

  SELECT * INTO v_row FROM public.shift_declarations WHERE id = v_dec;
  IF v_row.computed_rule <> 'zzp' OR v_row.computed_reimbursable_km IS NOT NULL
     OR v_row.rate_id IS NOT NULL OR v_row.computed_incomplete THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: opgeslagen als % met % km, tarief %, onvolledig %.',
      v_row.computed_rule, v_row.computed_reimbursable_km, v_row.rate_id, v_row.computed_incomplete;
  END IF;
  RAISE NOTICE 'GEVAL 5 geslaagd: de uitkomst is op te slaan en blijft leeg.';

  -- ══ GEVAL 6: de invulpagina weet het ════════════════════════════════
  SELECT * INTO v_row FROM public.declaration_by_token(v_token);
  IF v_row.is_contractor IS NOT TRUE THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: is_contractor is %; dan toont de pagina de reiskostenvraag alsnog.',
      v_row.is_contractor;
  END IF;
  IF v_row.expects_receipt IS TRUE THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: er wordt een bon verwacht van een zzp''er.';
  END IF;
  RAISE NOTICE 'GEVAL 6 geslaagd: de pagina krijgt te horen dat de reiskostenvraag niet hoort te verschijnen.';

  -- ══ GEVAL 7: er gaat niets naar de factuur ══════════════════════════
  -- Dit is waar het om begon: claims_travel staat op true en er staan 40 km
  -- opgegeven. Zonder de nieuwe tak zou dat naast de onkostenpost óók nog als
  -- reiskosten worden doorbelast.
  PERFORM public.set_pharmacy_rate(v_home, 50.00, 50.00, 50.00, 50.00, 0.00,
                                   v_day - 1, 'test 035');

  SELECT * INTO v_row FROM public.invoice_lines(v_home, v_day, v_day) WHERE shift_id = v_car;
  IF COALESCE(v_row.travel_amount, 0) <> 0 THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: er wordt % aan reiskosten doorbelast voor een zzp''er.',
      v_row.travel_amount;
  END IF;
  RAISE NOTICE 'GEVAL 7 geslaagd: de apotheek krijgt geen kilometervergoeding op de factuur.';

  RAISE NOTICE 'ALLE GEVALLEN GESLAAGD.';
END;
$$;

ROLLBACK;   -- niets van deze test blijft staan
