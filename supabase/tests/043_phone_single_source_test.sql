-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 043: één bron voor het telefoonnummer
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 043 eerst (of proefdraai 043 met ROLLBACK en daarna dit).
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: één transactie die op ROLLBACK eindigt.
--
-- ⚠ DE TEST SIMULEERT EERST EEN PLANNERSESSIE
--   employee_save() begint met IF NOT public.is_privileged() en weigert anders met
--   "Alleen planners mogen medewerkers beheren." In de SQL Editor is auth.uid() leeg,
--   dus zonder voorbereiding faalt de test op die controle. Zelfde patroon als in de
--   tests van 033, 034, 039 en 042: request.jwt.claim.sub én request.jwt.claims met
--   set_config(..., true), zodat het met de ROLLBACK verdwijnt.
--
-- WAT DE TEST DEKT
--   1. Een nieuwe medewerker krijgt GEEN phone, ook niet als hij wordt meegestuurd
--   2. Een bestaande phone blijft staan bij een update die phone meestuurt — dat is
--      de hele reden dat de kolom uit de UPDATE is gehaald in plaats van dat de
--      frontend stopt met sturen
--   3. Een bestaande phone blijft ook staan als phone NIET wordt meegestuurd
--   4. De rest van de velden wordt nog wel bijgewerkt
--   5. De afscherming werkt: zonder plannersessie weigert employee_save()
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
  v_planner UUID;
  v_courier UUID;
  v_id      UUID;
  v_row     public.employees;
BEGIN
  SELECT id INTO v_planner FROM public.user_profiles
   WHERE role IN ('superuser', 'supervisor', 'admin') ORDER BY id LIMIT 1;
  IF v_planner IS NULL THEN RAISE EXCEPTION 'OPZET: geen planner in user_profiles.'; END IF;
  SELECT id INTO v_courier FROM public.user_profiles WHERE role = 'courier' ORDER BY id LIMIT 1;
  IF v_courier IS NULL THEN RAISE EXCEPTION 'OPZET: geen koerier in user_profiles.'; END IF;

  PERFORM set_config('request.jwt.claim.sub', v_planner::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_planner, 'role', 'authenticated')::text, true);
  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'OPZET: is_privileged() geeft nog false na het zetten van de jwt-claims.';
  END IF;

  -- ── 1. Nieuw: phone wordt genegeerd ────────────────────────────────────
  v_id := public.employee_save(jsonb_build_object(
    'first_name', 'Test043', 'last_name', 'Nieuw',
    'phone', '+31600000001',
    'employment_type', 'loondienst'));

  SELECT * INTO v_row FROM public.employees WHERE id = v_id;
  IF v_row.phone IS NOT NULL THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: een nieuwe medewerker kreeg phone = %, verwacht NULL. '
                    'employee_save hoort dat veld te negeren.', v_row.phone;
  END IF;

  -- ── 2. Bestaande phone blijft staan als hij WEL wordt meegestuurd ──────
  -- Dit is het geval dat de uitrolvolgorde onschadelijk maakt: de frontend stuurt de
  -- oude waarde terug en die mag niets veranderen.
  UPDATE public.employees SET phone = '+31600000009' WHERE id = v_id;

  PERFORM public.employee_save(jsonb_build_object(
    'id', v_id, 'first_name', 'Test043', 'last_name', 'Gewijzigd',
    'phone', '+31600000002'));

  SELECT * INTO v_row FROM public.employees WHERE id = v_id;
  IF v_row.phone <> '+31600000009' THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: phone is % geworden, verwacht +31600000009 (ongewijzigd). '
                    'De kolom hoort niet meer in de UPDATE te staan.', v_row.phone;
  END IF;

  -- ── 3. En ook als hij NIET wordt meegestuurd ───────────────────────────
  PERFORM public.employee_save(jsonb_build_object(
    'id', v_id, 'first_name', 'Test043', 'last_name', 'Nogmaals'));

  SELECT * INTO v_row FROM public.employees WHERE id = v_id;
  IF v_row.phone <> '+31600000009' THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: phone is % geworden zonder dat hij werd meegestuurd. '
                    'Ingetypte nummers zijn het startpunt van de overzetting en mogen niet '
                    'gewist worden.', v_row.phone;
  END IF;

  -- ── 4. De rest werkt nog ───────────────────────────────────────────────
  IF v_row.last_name <> 'Nogmaals' THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: last_name is % in plaats van Nogmaals — de UPDATE doet '
                    'niets meer.', v_row.last_name;
  END IF;

  PERFORM public.employee_save(jsonb_build_object(
    'id', v_id, 'first_name', 'Test043', 'last_name', 'Nogmaals',
    'personnel_number', 'T043', 'employment_type', 'zzp'));
  SELECT * INTO v_row FROM public.employees WHERE id = v_id;
  IF v_row.personnel_number <> 'T043' OR v_row.employment_type <> 'zzp' THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: personeelsnummer of dienstverband is niet bijgewerkt.';
  END IF;

  -- ── 5. De afscherming ──────────────────────────────────────────────────
  PERFORM set_config('request.jwt.claim.sub', v_courier::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_courier, 'role', 'authenticated')::text, true);

  BEGIN
    PERFORM public.employee_save(jsonb_build_object(
      'first_name', 'Test043', 'last_name', 'Koerier'));
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: een koerierssessie mocht een medewerker opslaan.';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM NOT LIKE '%Alleen planners%' THEN RAISE; END IF;
  END;

  RAISE NOTICE 'Alle 5 gevallen geslaagd.';
END $$;

-- ────────────────────────────────────────────────────────────────────────
-- Stand na afloop, ter controle vóór de rollback.
-- ────────────────────────────────────────────────────────────────────────
SELECT count(*) AS met_phone_in_employees FROM public.employees
WHERE NULLIF(btrim(COALESCE(phone, '')), '') IS NOT NULL;

ROLLBACK;   -- er blijft niets van deze test achter
