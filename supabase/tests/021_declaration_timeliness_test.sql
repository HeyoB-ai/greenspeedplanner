-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 021: op tijd ingediend, als afgeleide
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 021 eerst (of proefdraai 021 met ROLLBACK en daarna dit).
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: één transactie die op ROLLBACK eindigt.
--
-- ┌─ WAAROM set_config VAN DE JWT-CLAIMS ──────────────────────────────────┐
-- │ declaration_overview() filtert op is_privileged(), en die leest         │
-- │ auth.uid(). In de SQL Editor draai je als postgres zonder uid, dus      │
-- │ zonder deze regels geeft de functie nul rijen en bewijst de test niets. │
-- │ De rol wisselen is hier niet nodig — de functie is SECURITY DEFINER —   │
-- │ en zou het klaarzetten van de testdata juist in de weg zitten.          │
-- └─────────────────────────────────────────────────────────────────────────┘
--
-- WAT DE TEST DEKT
--   1. De instelling staat er en is uitleesbaar (48 uur als standaard)
--   2. Binnen de termijn ingediend  → in_time = true, uren kloppen
--   3. Buiten de termijn ingediend  → in_time = false, uren kloppen
--   4. Nog niet ingediend           → in_time = NULL, maar wél de uren dat hij
--                                     al openstaat
--   5. De termijn is instelbaar     → op 72 uur is dezelfde rij ineens op tijd
--   6. Te laat ingediend            → de link werkt gewoon nog
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
  v_courier UUID;
  v_planner UUID;
  v_home    TEXT;
  v_day     DATE := current_date - 3;
  v_s_ontijd UUID;
  v_s_telaat UUID;
  v_s_open   UUID;
  v_d_ontijd UUID;
  v_d_telaat UUID;
  v_d_open   UUID;
  v_token    TEXT := 'test-token-021';
  v_row      RECORD;
BEGIN
  -- ── Voorbereiding ────────────────────────────────────────────────────
  SELECT id INTO v_courier FROM public.user_profiles WHERE role = 'courier' ORDER BY id LIMIT 1;
  IF v_courier IS NULL THEN RAISE EXCEPTION 'OPZET: geen koerier in user_profiles.'; END IF;
  SELECT id INTO v_planner FROM public.user_profiles
   WHERE role IN ('superuser','supervisor','admin') ORDER BY id LIMIT 1;
  IF v_planner IS NULL THEN RAISE EXCEPTION 'OPZET: geen planner in user_profiles.'; END IF;
  SELECT id INTO v_home FROM public.pharmacies ORDER BY id LIMIT 1;

  UPDATE public.declaration_settings SET expected_within_hours = 48;

  -- ── GEVAL 1: de instelling is uitleesbaar ────────────────────────────
  IF public.declaration_expected_hours() <> 48 THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: declaration_expected_hours() gaf %, verwacht 48.',
      public.declaration_expected_hours();
  END IF;
  RAISE NOTICE 'GEVAL 1 geslaagd: de termijn staat in de database en is uitleesbaar.';

  -- Drie diensten van drie dagen terug, 08:00-12:00.
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '08:00', '12:00', 'planned', 'bike')
  RETURNING id INTO v_s_ontijd;
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '13:00', '17:00', 'planned', 'bike')
  RETURNING id INTO v_s_telaat;
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '18:00', '20:00', 'planned', 'bike')
  RETURNING id INTO v_s_open;

  IF v_home IS NOT NULL THEN
    INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id)
    VALUES (v_s_ontijd, v_home), (v_s_telaat, v_home), (v_s_open, v_home);
  END IF;

  -- Drie declaraties: op tijd, te laat, en nog niets ingevuld.
  INSERT INTO public.shift_declarations (shift_id, courier_id, token_hash, token_expires_at)
  VALUES (v_s_ontijd, v_courier, public.declaration_hash_token(v_token || '-a'), now() + INTERVAL '30 days')
  RETURNING id INTO v_d_ontijd;
  INSERT INTO public.shift_declarations (shift_id, courier_id, token_hash, token_expires_at)
  VALUES (v_s_telaat, v_courier, public.declaration_hash_token(v_token || '-b'), now() + INTERVAL '30 days')
  RETURNING id INTO v_d_telaat;
  INSERT INTO public.shift_declarations (shift_id, courier_id, token_hash, token_expires_at)
  VALUES (v_s_open, v_courier, public.declaration_hash_token(v_token || '-c'), now() + INTERVAL '30 days')
  RETURNING id INTO v_d_open;

  -- Vijf uur na de eindtijd ingediend, en zeventig uur na de eindtijd.
  UPDATE public.shift_declarations
     SET status = 'submitted', actual_start = '08:00', actual_end = '12:15',
         claims_travel = false,
         submitted_at = public.declaration_shift_end(v_day, TIME '08:00', TIME '12:00') + INTERVAL '5 hours'
   WHERE id = v_d_ontijd;

  UPDATE public.shift_declarations
     SET status = 'submitted', actual_start = '13:00', actual_end = '17:30',
         claims_travel = false,
         submitted_at = public.declaration_shift_end(v_day, TIME '13:00', TIME '17:00') + INTERVAL '70 hours'
   WHERE id = v_d_telaat;

  -- Vanaf hier doen we ons voor als de PLANNER, anders geeft het overzicht niets.
  PERFORM set_config('request.jwt.claim.sub', v_planner::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_planner, 'role', 'authenticated')::text, true);

  -- ── GEVAL 2: binnen de termijn ───────────────────────────────────────
  SELECT * INTO v_row FROM public.declaration_overview(v_day, v_day)
   WHERE declaration_id = v_d_ontijd;
  IF v_row.declaration_id IS NULL THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: het overzicht gaf geen rij — draait de test wel als planner?';
  END IF;
  IF v_row.submitted_in_time IS NOT TRUE THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: vijf uur na afloop geldt niet als op tijd (in_time=%).', v_row.submitted_in_time;
  END IF;
  IF round(v_row.hours_after_end) <> 5 THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: % uur na afloop, verwacht 5.', v_row.hours_after_end;
  END IF;
  IF v_row.expected_within_hours <> 48 THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: de termijn komt niet mee in het overzicht (%).', v_row.expected_within_hours;
  END IF;
  RAISE NOTICE 'GEVAL 2 geslaagd: vijf uur na afloop is op tijd, met de uren en de termijn erbij.';

  -- ── GEVAL 3: buiten de termijn ───────────────────────────────────────
  SELECT * INTO v_row FROM public.declaration_overview(v_day, v_day)
   WHERE declaration_id = v_d_telaat;
  IF v_row.submitted_in_time IS NOT FALSE THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: zeventig uur na afloop geldt als op tijd (in_time=%).', v_row.submitted_in_time;
  END IF;
  IF round(v_row.hours_after_end) <> 70 THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: % uur na afloop, verwacht 70.', v_row.hours_after_end;
  END IF;
  RAISE NOTICE 'GEVAL 3 geslaagd: zeventig uur na afloop valt buiten de termijn.';

  -- ── GEVAL 4: nog niet ingediend ──────────────────────────────────────
  SELECT * INTO v_row FROM public.declaration_overview(v_day, v_day)
   WHERE declaration_id = v_d_open;
  IF v_row.submitted_in_time IS NOT NULL THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: een rij zonder opgave krijgt een oordeel (in_time=%). Niet ingediend is niet te laat.', v_row.submitted_in_time;
  END IF;
  IF v_row.hours_after_end IS NULL OR v_row.hours_after_end < 48 THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: openstaande rij meldt % uur; verwacht de tijd sinds de eindtijd (ruim 48).', v_row.hours_after_end;
  END IF;
  RAISE NOTICE 'GEVAL 4 geslaagd: een openstaande rij toont hoe lang hij al openstaat, zonder oordeel.';

  -- ── GEVAL 5: de termijn is instelbaar ────────────────────────────────
  UPDATE public.declaration_settings SET expected_within_hours = 72;

  SELECT * INTO v_row FROM public.declaration_overview(v_day, v_day)
   WHERE declaration_id = v_d_telaat;
  IF v_row.submitted_in_time IS NOT TRUE OR v_row.expected_within_hours <> 72 THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: bij 72 uur hoort dezelfde rij op tijd te zijn (in_time=%, termijn=%). De termijn zit ergens vast in code.',
      v_row.submitted_in_time, v_row.expected_within_hours;
  END IF;
  RAISE NOTICE 'GEVAL 5 geslaagd: de termijn komt uit de instelling en nergens anders vandaan.';

  UPDATE public.declaration_settings SET expected_within_hours = 48;

  -- ── GEVAL 6: te laat ingediend, en de link werkt nog ─────────────────
  -- De termijn is een verwachting, geen grens: token_valid_days blijft leidend.
  IF NOT EXISTS (SELECT 1 FROM public.declaration_by_token(v_token || '-b')) THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: de link van een te laat ingediende declaratie doet het niet meer.';
  END IF;
  RAISE NOTICE 'GEVAL 6 geslaagd: te laat ingediend verandert niets aan de geldigheid van de link.';

  RAISE NOTICE 'ALLE GEVALLEN GESLAAGD.';
END $$;

ROLLBACK;
