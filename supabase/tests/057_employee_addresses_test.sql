-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 057: het woonadres van een medewerker wordt bewaard
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 057 eerst (of proefdraai 057 met ROLLBACK en daarna dit).
--
-- UITKOMST
--   Alleen de melding "057: alle gevallen geslaagd" → alles in orde.
--   Een melding met GEFAALD → de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: één transactie die op ROLLBACK eindigt. Ook een
-- bestaand adres van een echte koerier wordt hooguit binnen die transactie
-- overschreven en daarna teruggezet.
--
-- ⚠ DE TEST SIMULEERT EEN PLANNERSESSIE
--   courier_address_get/_set en courier_home_overview() controleren
--   is_privileged(), en in de SQL Editor is auth.uid() leeg. Zelfde patroon als in
--   de tests van 033 tot en met 043: request.jwt.claim.sub én request.jwt.claims
--   met set_config(..., true), zodat het met de ROLLBACK verdwijnt.
--
-- WAT DE TEST DEKT
--    1. Opslaan en teruglezen, met spaties eromheen weggehaald
--    2. courier_home_overview() meldt has_address
--    3. Een lege regel verwijdert het adres
--    4. Een te kort adres wordt geweigerd — door de functie én door de CHECK
--    5. Een koerier zonder medewerkerregel geeft een duidelijke fout
--    6. Een koerier (geen planner) mag niet lezen en niet schrijven
--    7. De rechten op courier_home_overview() zijn er nog na de DROP FUNCTION —
--       de les van 6 oktober, toen declaration_overview zijn EXECUTE kwijtraakte
--    8. De rechten op de adresfuncties en op de tabel
--    9. Geen audit-trigger, en het adres staat nergens in audit_log
--   10. Een verwijderde medewerker neemt zijn adres mee (alleen bij een
--       testmedewerker die deze test zelf aanmaakt)
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
  TESTADRES CONSTANT TEXT := 'Teststraat 57, 1234 AB Testdorp';
  v_planner  UUID;
  v_courier  UUID;
  v_employee UUID;
  v_eigen    BOOLEAN := false;   -- maakte deze test de medewerker zelf aan?
  v_adres    TEXT;
  v_has      BOOLEAN;
  v_err      TEXT;
  v_state    TEXT;
BEGIN
  -- ── Opzet ──────────────────────────────────────────────────────────────
  SELECT id INTO v_planner FROM public.user_profiles
   WHERE role IN ('superuser', 'supervisor', 'admin') ORDER BY id LIMIT 1;
  IF v_planner IS NULL THEN RAISE EXCEPTION 'OPZET: geen planner in user_profiles.'; END IF;

  -- Een koerier mét medewerkerregel. Is die er niet, dan krijgt een koerier
  -- zonder regel er binnen deze transactie een.
  SELECT up.id, e.id INTO v_courier, v_employee
  FROM public.user_profiles up
  JOIN public.employees e ON e.user_profile_id = up.id
  WHERE up.role = 'courier' ORDER BY up.id LIMIT 1;

  IF v_courier IS NULL THEN
    SELECT up.id INTO v_courier FROM public.user_profiles up
    WHERE up.role = 'courier'
      AND NOT EXISTS (SELECT 1 FROM public.employees e WHERE e.user_profile_id = up.id)
    ORDER BY up.id LIMIT 1;
    IF v_courier IS NULL THEN RAISE EXCEPTION 'OPZET: geen koerier in user_profiles.'; END IF;

    INSERT INTO public.employees (first_name, last_name, user_profile_id)
    VALUES ('Test057', 'Adres', v_courier)
    RETURNING id INTO v_employee;
    v_eigen := true;
  END IF;

  PERFORM set_config('request.jwt.claim.sub', v_planner::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_planner, 'role', 'authenticated')::text, true);
  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'OPZET: is_privileged() geeft nog false na het zetten van de jwt-claims.';
  END IF;

  -- ── 1. Opslaan en teruglezen ───────────────────────────────────────────
  PERFORM public.courier_address_set(v_courier, '   ' || TESTADRES || '  ');
  v_adres := public.courier_address_get(v_courier);
  IF v_adres IS DISTINCT FROM TESTADRES THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: teruggelezen "%", verwacht "%" (spaties eromheen horen weg).',
                    v_adres, TESTADRES;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.employee_addresses
                 WHERE employee_id = v_employee AND updated_by = v_planner) THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: updated_by is niet de planner die het adres opsloeg.';
  END IF;

  -- ── 2. has_address ─────────────────────────────────────────────────────
  SELECT o.has_address INTO v_has FROM public.courier_home_overview() o WHERE o.courier_id = v_courier;
  IF v_has IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: has_address is % na het opslaan, verwacht true.', v_has;
  END IF;

  -- ── 3. Leeg is verwijderen ─────────────────────────────────────────────
  PERFORM public.courier_address_set(v_courier, '   ');
  IF EXISTS (SELECT 1 FROM public.employee_addresses WHERE employee_id = v_employee) THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: een lege regel liet het adres staan.';
  END IF;
  IF public.courier_address_get(v_courier) IS NOT NULL THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: get geeft nog een adres na verwijderen.';
  END IF;
  SELECT o.has_address INTO v_has FROM public.courier_home_overview() o WHERE o.courier_id = v_courier;
  IF v_has IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: has_address is % na verwijderen, verwacht false.', v_has;
  END IF;

  -- ── 4. Te kort ─────────────────────────────────────────────────────────
  v_err := NULL;
  BEGIN
    PERFORM public.courier_address_set(v_courier, 'abc');
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM;
  END;
  IF v_err IS NULL OR v_err NOT LIKE '%volledig adres%' THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: "abc" werd niet met een leesbare melding geweigerd (kreeg: %).', v_err;
  END IF;

  v_state := NULL;
  BEGIN
    INSERT INTO public.employee_addresses (employee_id, address_line) VALUES (v_employee, '  x  ');
  EXCEPTION WHEN check_violation THEN v_state := SQLSTATE;
  END;
  IF v_state IS DISTINCT FROM '23514' THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: de CHECK liet een adres van één teken toe.';
  END IF;

  -- ── 5. Geen medewerkerregel ────────────────────────────────────────────
  v_err := NULL;
  BEGIN
    PERFORM public.courier_address_get(gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM;
  END;
  IF v_err IS NULL OR v_err NOT LIKE '%geen medewerkerregel%' THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: get zonder medewerkerregel gaf geen duidelijke fout (kreeg: %).', v_err;
  END IF;
  v_err := NULL;
  BEGIN
    PERFORM public.courier_address_set(gen_random_uuid(), TESTADRES);
  EXCEPTION WHEN OTHERS THEN v_err := SQLERRM;
  END;
  IF v_err IS NULL OR v_err NOT LIKE '%geen medewerkerregel%' THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: set zonder medewerkerregel gaf geen duidelijke fout (kreeg: %).', v_err;
  END IF;

  -- ── 9. Niet in het logboek ─────────────────────────────────────────────
  -- Nu, met een adres erin, en vóór geval 6 de sessie omzet.
  PERFORM public.courier_address_set(v_courier, TESTADRES);
  IF EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
             WHERE t.tgrelid = 'public.employee_addresses'::regclass AND p.proname = 'audit_capture') THEN
    RAISE EXCEPTION 'GEVAL 9 GEFAALD: er staat een audit-trigger op employee_addresses.';
  END IF;
  IF to_regclass('public.audit_log') IS NOT NULL THEN
    EXECUTE $q$SELECT EXISTS (SELECT 1 FROM public.audit_log
                              WHERE strpos(COALESCE(old_data::text, '') || COALESCE(new_data::text, ''), $1) > 0)$q$
      INTO v_has USING TESTADRES;
    IF v_has THEN
      RAISE EXCEPTION 'GEVAL 9 GEFAALD: het testadres staat in audit_log.';
    END IF;
  END IF;

  -- ── 6. Een koerier mag niet ────────────────────────────────────────────
  PERFORM set_config('request.jwt.claim.sub', v_courier::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_courier, 'role', 'authenticated')::text, true);

  v_state := NULL;
  BEGIN
    PERFORM public.courier_address_get(v_courier);
  EXCEPTION WHEN OTHERS THEN v_state := SQLSTATE;
  END;
  IF v_state IS DISTINCT FROM '42501' THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: een koerier kon zijn eigen adres opvragen (sqlstate %).', v_state;
  END IF;

  v_state := NULL;
  BEGIN
    PERFORM public.courier_address_set(v_courier, 'Ergens anders 1, 9999 ZZ Elders');
  EXCEPTION WHEN OTHERS THEN v_state := SQLSTATE;
  END;
  IF v_state IS DISTINCT FROM '42501' THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: een koerier kon een adres wijzigen (sqlstate %).', v_state;
  END IF;

  IF EXISTS (SELECT 1 FROM public.courier_home_overview()) THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: courier_home_overview() geeft rijen aan een koerier.';
  END IF;

  -- Terug naar de planner voor het laatste geval.
  PERFORM set_config('request.jwt.claim.sub', v_planner::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_planner, 'role', 'authenticated')::text, true);

  -- ── 7. EXECUTE op courier_home_overview() na de DROP ──────────────────
  IF NOT has_function_privilege('authenticated', 'public.courier_home_overview()', 'EXECUTE') THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: authenticated mag courier_home_overview() niet meer uitvoeren. '
                    'Dit is precies wat declaration_overview op 6 oktober overkwam — '
                    'de GRANT na de DROP FUNCTION ontbreekt.';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.courier_home_overview()', 'EXECUTE') THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: service_role mag courier_home_overview() niet meer uitvoeren.';
  END IF;
  IF has_function_privilege('anon', 'public.courier_home_overview()', 'EXECUTE') THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: anon mag courier_home_overview() uitvoeren.';
  END IF;

  -- ── 8. Rechten op de functies en de tabel ──────────────────────────────
  IF NOT has_function_privilege('authenticated', 'public.courier_address_get(uuid)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.courier_address_set(uuid, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'GEVAL 8 GEFAALD: authenticated mist EXECUTE op een van de adresfuncties.';
  END IF;
  IF has_function_privilege('anon', 'public.courier_address_get(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.courier_address_set(uuid, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'GEVAL 8 GEFAALD: anon mag een adresfunctie uitvoeren.';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.employee_addresses'::regclass) THEN
    RAISE EXCEPTION 'GEVAL 8 GEFAALD: RLS staat uit op employee_addresses.';
  END IF;
  IF (SELECT count(*) FROM pg_policy WHERE polrelid = 'public.employee_addresses'::regclass) <> 1 THEN
    RAISE EXCEPTION 'GEVAL 8 GEFAALD: employee_addresses heeft niet precies één policy.';
  END IF;
  IF has_table_privilege('anon', 'public.employee_addresses', 'SELECT')
     OR has_table_privilege('authenticated', 'public.employee_addresses', 'SELECT') THEN
    RAISE EXCEPTION 'GEVAL 8 GEFAALD: anon of authenticated kan de adrestabel rechtstreeks lezen.';
  END IF;
  IF NOT has_table_privilege('service_role', 'public.employee_addresses', 'SELECT')
     OR NOT has_table_privilege('service_role', 'public.employees', 'SELECT') THEN
    RAISE EXCEPTION 'GEVAL 8 GEFAALD: service_role kan employee_addresses of employees niet lezen — '
                    'dan faalt de Edge Function courier-distances op het bewaarde adres.';
  END IF;
  IF has_table_privilege('service_role', 'public.employee_addresses', 'INSERT')
     OR has_table_privilege('service_role', 'public.employee_addresses', 'UPDATE') THEN
    RAISE EXCEPTION 'GEVAL 8 GEFAALD: service_role mag adressen schrijven; dat hoort alleen via courier_address_set.';
  END IF;

  -- ── 10. Cascade bij verwijderen ────────────────────────────────────────
  IF v_eigen THEN
    DELETE FROM public.employees WHERE id = v_employee;
    IF EXISTS (SELECT 1 FROM public.employee_addresses WHERE employee_id = v_employee) THEN
      RAISE EXCEPTION 'GEVAL 10 GEFAALD: het adres bleef staan na het verwijderen van de medewerker.';
    END IF;
  ELSE
    RAISE NOTICE '057: geval 10 overgeslagen — de test gebruikte een bestaande medewerker en verwijdert die niet.';
  END IF;

  RAISE NOTICE '057: alle gevallen geslaagd.';
END $$;

ROLLBACK;
