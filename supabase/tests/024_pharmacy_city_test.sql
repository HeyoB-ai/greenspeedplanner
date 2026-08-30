-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 024: plaatsnaam bewerkbaar
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 024 eerst (of proefdraai 024 met ROLLBACK en daarna dit).
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: één transactie die op ROLLBACK eindigt. De plaats van
-- de gebruikte apotheek wordt onderweg gewijzigd en draait met de rollback terug.
--
-- WAT DE TEST DEKT
--   1. De kolom bestaat en is te lezen
--   2. Planner zet een plaats                → wordt opgeslagen, getrimd
--   3. Leeg opslaan                          → wist het veld (terug naar "Overig")
--   4. Onbekende apotheek                    → duidelijke fout, geen stille no-op
--   5. Niet-planner                          → geweigerd
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
  v_pharm   TEXT;
  v_courier UUID;
  v_planner UUID;
  v_before  TEXT;
  v_msg     TEXT;
BEGIN
  SELECT id, city INTO v_pharm, v_before FROM public.pharmacies ORDER BY id LIMIT 1;
  IF v_pharm IS NULL THEN RAISE EXCEPTION 'OPZET: geen apotheek in pharmacies.'; END IF;

  SELECT id INTO v_planner FROM public.user_profiles
   WHERE role IN ('superuser','supervisor','admin') ORDER BY id LIMIT 1;
  IF v_planner IS NULL THEN RAISE EXCEPTION 'OPZET: geen planner in user_profiles.'; END IF;
  SELECT id INTO v_courier FROM public.user_profiles WHERE role = 'courier' ORDER BY id LIMIT 1;

  -- ── GEVAL 1: de kolom bestaat ────────────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'pharmacies' AND column_name = 'city'
  ) THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: pharmacies.city bestaat niet.';
  END IF;
  RAISE NOTICE 'GEVAL 1 geslaagd: de kolom staat er (% van % apotheken heeft er een waarde in).',
    (SELECT count(city) FROM public.pharmacies), (SELECT count(*) FROM public.pharmacies);

  -- Vanaf hier doen we ons voor als de PLANNER: set_pharmacy_city controleert
  -- op is_privileged(), en die leest auth.uid().
  PERFORM set_config('request.jwt.claim.sub', v_planner::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_planner, 'role', 'authenticated')::text, true);

  -- ── GEVAL 2: plaats zetten ───────────────────────────────────────────
  PERFORM public.set_pharmacy_city(v_pharm, '  Hilversum  ');
  IF (SELECT city FROM public.pharmacies WHERE id = v_pharm) <> 'Hilversum' THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: plaats is % — verwacht Hilversum, zonder spaties.',
      (SELECT city FROM public.pharmacies WHERE id = v_pharm);
  END IF;
  RAISE NOTICE 'GEVAL 2 geslaagd: de planner zet een plaats en de spaties gaan eraf.';

  -- ── GEVAL 3: leeg wist het veld ──────────────────────────────────────
  PERFORM public.set_pharmacy_city(v_pharm, '   ');
  IF (SELECT city FROM public.pharmacies WHERE id = v_pharm) IS NOT NULL THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: leeg opslaan liet er een lege tekst staan in plaats van NULL.';
  END IF;
  RAISE NOTICE 'GEVAL 3 geslaagd: leeg opslaan wist de plaats (apotheek valt terug op "Overig").';

  -- ── GEVAL 4: onbekende apotheek ──────────────────────────────────────
  BEGIN
    PERFORM public.set_pharmacy_city('ph-bestaat-niet-024', 'Hilversum');
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: een onbekende apotheek leverde geen fout op.';
  EXCEPTION WHEN raise_exception THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg LIKE 'GEVAL 4 GEFAALD%' THEN RAISE; END IF;
    RAISE NOTICE 'GEVAL 4 geslaagd: een onbekende apotheek geeft een fout (%).', v_msg;
  END;

  -- ── GEVAL 5: een koerier mag dit niet ────────────────────────────────
  IF v_courier IS NULL THEN
    RAISE WARNING 'GEVAL 5 OVERGESLAGEN: geen koerier in user_profiles.';
  ELSE
    PERFORM set_config('request.jwt.claim.sub', v_courier::text, true);
    PERFORM set_config('request.jwt.claims',
                       json_build_object('sub', v_courier, 'role', 'authenticated')::text, true);
    BEGIN
      PERFORM public.set_pharmacy_city(v_pharm, 'Amsterdam');
      RAISE EXCEPTION 'GEVAL 5 GEFAALD: een koerier kon de plaats van een apotheek wijzigen.';
    EXCEPTION WHEN raise_exception THEN
      GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
      IF v_msg LIKE 'GEVAL 5 GEFAALD%' THEN RAISE; END IF;
      RAISE NOTICE 'GEVAL 5 geslaagd: geweigerd voor een niet-planner (%).', v_msg;
    END;
  END IF;

  RAISE NOTICE 'ALLE GEVALLEN GESLAAGD.';
END $$;

ROLLBACK;
