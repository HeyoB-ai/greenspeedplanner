-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 029: personeelsadministratie
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 029 eerst (of proefdraai 029 met ROLLBACK en daarna dit).
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: één transactie die op ROLLBACK eindigt.
--
-- WAT DE TEST DEKT
--   1. Medewerker zonder inlogaccount        → kan gewoon bestaan
--   2. Uit dienst is een datum                → verdwijnt uit "actief", blijft staan
--   3. employee_active_on op een oude datum   → toen wél in dienst
--   4. Import                                 → nieuw, bijgewerkt, en niet gedupliceerd
--   5. Import zonder personeelsnummer         → aangemaakt mét markering
--   6. Import laat lege kolommen staan        → een leeg veld overschrijft niets
--   7. De vijf bestaande koeriers             → overgenomen met user_profile_id
--   8. Verwijderd profiel                     → medewerker blijft, koppeling leeg
--   9. Niet-planner                           → mag niets
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
  v_planner UUID;
  v_courier UUID;
  v_pharm   TEXT;
  v_id      UUID;
  v_id2     UUID;
  v_n       INT;
  v_row     RECORD;
  v_msg     TEXT;
BEGIN
  SELECT id INTO v_planner FROM public.user_profiles
   WHERE role IN ('superuser','supervisor','admin') ORDER BY id LIMIT 1;
  IF v_planner IS NULL THEN RAISE EXCEPTION 'OPZET: geen planner in user_profiles.'; END IF;
  SELECT id INTO v_courier FROM public.user_profiles WHERE role = 'courier' ORDER BY id LIMIT 1;
  SELECT id INTO v_pharm FROM public.pharmacies ORDER BY id LIMIT 1;

  PERFORM set_config('request.jwt.claim.sub', v_planner::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_planner, 'role', 'authenticated')::text, true);

  -- ══ GEVAL 7 eerst: de overname is al gedaan door de migratie ════════
  SELECT count(*) INTO v_n
  FROM public.employees e JOIN public.user_profiles up ON up.id = e.user_profile_id
  WHERE up.role = 'courier';
  IF v_n <> (SELECT count(*) FROM public.user_profiles WHERE role = 'courier') THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: % koeriers overgenomen van %.',
      v_n, (SELECT count(*) FROM public.user_profiles WHERE role = 'courier');
  END IF;
  RAISE NOTICE 'GEVAL 7 geslaagd: alle % koeriers hebben een medewerkersrij met inlogaccount.', v_n;

  -- ══ GEVAL 1: medewerker zonder inlogaccount ═════════════════════════
  SELECT public.employee_save(jsonb_build_object(
    'personnel_number', 'T-029-1',
    'first_name', 'Test', 'last_name', 'Zonder Account',
    'employment_type', 'loondienst',
    'employed_from', (current_date - 30)::TEXT,
    'home_pharmacy_id', v_pharm)) INTO v_id;

  IF (SELECT user_profile_id FROM public.employees WHERE id = v_id) IS NOT NULL THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: er hangt een profiel aan een medewerker die er geen heeft.';
  END IF;
  IF NOT public.employee_active_on(v_id, current_date) THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: een medewerker in dienst geldt niet als actief.';
  END IF;
  RAISE NOTICE 'GEVAL 1 geslaagd: een medewerker zonder inlogaccount kan bestaan.';

  -- ══ GEVAL 2 en 3: uit dienst is een datum ═══════════════════════════
  PERFORM public.employee_save(jsonb_build_object(
    'id', v_id::TEXT,
    'first_name', 'Test', 'last_name', 'Zonder Account',
    'employed_from', (current_date - 30)::TEXT,
    'employed_until', (current_date - 5)::TEXT));

  IF public.employee_active_on(v_id, current_date) THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: iemand met een einddatum in het verleden geldt nog als actief.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.employees WHERE id = v_id) THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: de rij is verdwenen. Uit dienst is een datum, geen verwijdering.';
  END IF;
  IF (SELECT is_active FROM public.employees_active WHERE id = v_id) THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: de view zegt actief terwijl de functie dat niet doet.';
  END IF;
  RAISE NOTICE 'GEVAL 2 geslaagd: uit dienst verdwijnt uit actief, de rij blijft staan.';

  IF NOT public.employee_active_on(v_id, current_date - 10) THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: tien dagen geleden was hij wél in dienst; een urenexport over die periode hoort hem te bevatten.';
  END IF;
  RAISE NOTICE 'GEVAL 3 geslaagd: op een datum binnen het dienstverband telt hij gewoon mee.';

  -- ══ GEVAL 4: import ═════════════════════════════════════════════════
  SELECT count(*) INTO v_n FROM public.employee_import('[
    {"personnel_number": "T-029-100", "first_name": "Import", "last_name": "Een",
     "employment_type": "zzp", "phone": "0612345678"},
    {"personnel_number": "T-029-101", "first_name": "Import", "last_name": "Twee"}
  ]'::JSONB) WHERE action = 'nieuw';
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: % nieuwe rijen, verwacht 2.', v_n;
  END IF;

  -- Dezelfde lijst opnieuw: bijwerken, niet dupliceren.
  SELECT count(*) INTO v_n FROM public.employee_import('[
    {"personnel_number": "T-029-100", "first_name": "Import", "last_name": "Een"}
  ]'::JSONB) WHERE action = 'bijgewerkt';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: een tweede import maakte geen bijwerking maar iets anders.';
  END IF;
  IF (SELECT count(*) FROM public.employees WHERE personnel_number = 'T-029-100') <> 1 THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: de medewerker is gedupliceerd.';
  END IF;
  RAISE NOTICE 'GEVAL 4 geslaagd: importeren is te herhalen zonder dubbele rijen.';

  -- ══ GEVAL 6: lege kolommen overschrijven niets ══════════════════════
  IF (SELECT phone FROM public.employees WHERE personnel_number = 'T-029-100') IS NULL THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: het telefoonnummer is gewist door een lijst zonder die kolom.';
  END IF;
  RAISE NOTICE 'GEVAL 6 geslaagd: een ontbrekende kolom laat staan wat er stond.';

  -- ══ GEVAL 5: zonder personeelsnummer ════════════════════════════════
  SELECT * INTO v_row FROM public.employee_import('[
    {"first_name": "Geen", "last_name": "Nummer"}
  ]'::JSONB);
  IF v_row.action <> 'nieuw' THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: iemand zonder personeelsnummer werd % in plaats van aangemaakt.', v_row.action;
  END IF;
  IF v_row.note IS NULL OR v_row.note NOT LIKE '%personeelsnummer%' THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: geen markering bij een ontbrekend personeelsnummer (%).', v_row.note;
  END IF;
  RAISE NOTICE 'GEVAL 5 geslaagd: zonder nummer wordt hij aangemaakt mét markering (%).', v_row.note;

  -- Twee keer zonder nummer botst niet op de unieke index.
  PERFORM public.employee_import('[{"first_name": "Ook Geen", "last_name": "Nummer"}]'::JSONB);
  IF (SELECT count(*) FROM public.employees WHERE personnel_number IS NULL
        AND last_name = 'Nummer') <> 2 THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: een tweede medewerker zonder nummer paste er niet bij.';
  END IF;

  -- ══ GEVAL 8: een verwijderd profiel neemt niets mee ═════════════════
  -- Nagebootst met een UPDATE naar NULL: het echte geval is een DELETE op
  -- auth.users, en die cascade zet deze kolom via ON DELETE SET NULL op NULL.
  -- Zou de FK op CASCADE staan, dan verdween hier de hele medewerker.
  IF v_courier IS NOT NULL THEN
    SELECT id INTO v_id2 FROM public.employees WHERE user_profile_id = v_courier;
    PERFORM public.employee_link_profile(v_id2, NULL);
    IF NOT EXISTS (SELECT 1 FROM public.employees WHERE id = v_id2) THEN
      RAISE EXCEPTION 'GEVAL 8 GEFAALD: de medewerker verdween met de koppeling.';
    END IF;
    IF (SELECT user_profile_id FROM public.employees WHERE id = v_id2) IS NOT NULL THEN
      RAISE EXCEPTION 'GEVAL 8 GEFAALD: de koppeling is niet losgemaakt.';
    END IF;
    RAISE NOTICE 'GEVAL 8 geslaagd: zonder inlogaccount blijft de medewerker en zijn historie bestaan.';
  ELSE
    RAISE WARNING 'GEVAL 8 OVERGESLAGEN: geen koerier in user_profiles.';
  END IF;

  -- ══ GEVAL 9: een koerier mag hier niets ═════════════════════════════
  IF v_courier IS NOT NULL THEN
    PERFORM set_config('request.jwt.claim.sub', v_courier::text, true);
    PERFORM set_config('request.jwt.claims',
                       json_build_object('sub', v_courier, 'role', 'authenticated')::text, true);
    BEGIN
      PERFORM public.employee_save(jsonb_build_object(
        'first_name', 'Stiekem', 'last_name', 'Erbij'));
      RAISE EXCEPTION 'GEVAL 9 GEFAALD: een koerier kon een medewerker aanmaken.';
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
      IF v_msg LIKE 'GEVAL 9 GEFAALD%' THEN RAISE; END IF;
      RAISE NOTICE 'GEVAL 9 geslaagd: geweigerd voor een niet-planner (%).', v_msg;
    END;
  END IF;

  RAISE NOTICE 'ALLE GEVALLEN GESLAAGD.';
END $$;

ROLLBACK;
