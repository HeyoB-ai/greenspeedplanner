-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 010: exception-vangnet bij verwijderde roosterconcepten
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai 010 eerst.
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan. De gevallen 2 t/m 5 zitten in één transactie die op
-- ROLLBACK eindigt; faalt een assertie, dan breekt de transactie af en wordt er
-- evengoed niets geschreven. Geval 1 raakt geen enkele tabel — dat zet en leest
-- alleen een GUC.
--
-- WAT DE TEST DEKT
--   1. Vlag-levensduur — de vlag geldt binnen de transactie en is ná COMMIT weg
--      (de enige toets die twee transacties nodig heeft, en daarom vooraan)
--   2. Rauwe SQL-delete van een roosterconcept  → exception WORDT vastgelegd
--   3. remove_future_schedule_drafts()          → GEEN exception, en bevestigde
--                                                 diensten blijven staan
--   4. Na de RPC lift een volgende delete in DEZELFDE transactie NIET mee op de
--      vlag
--   5. Een vlagwaarde uit een ANDERE transactie onderdrukt niets — het bewijs
--      dat een blijven hangen waarde nooit stilzwijgend kan doorwerken
-- ════════════════════════════════════════════════════════════════════════


-- ════════════════════════════════════════════════════════════════════════
-- GEVAL 1 — vlag-levensduur (raakt geen enkele tabel)
-- ════════════════════════════════════════════════════════════════════════
BEGIN;

  -- Zelfde aanroep als in remove_future_schedule_drafts: is_local => true.
  SELECT set_config('app.suppress_schedule_exception', pg_current_xact_id()::text, true);

  DO $$
  BEGIN
    IF COALESCE(current_setting('app.suppress_schedule_exception', true), '')
       <> pg_current_xact_id()::text THEN
      RAISE EXCEPTION 'GEVAL 1 GEFAALD: vlag geldt niet binnen de eigen transactie.';
    END IF;
  END;
  $$;

COMMIT;

-- Nieuwe transactie. Een SET LOCAL-waarde hoort de COMMIT niet te overleven;
-- zou dat wel zo zijn, dan kon hij via een hergebruikte poolerverbinding in een
-- wildvreemd verzoek terechtkomen.
DO $$
BEGIN
  IF COALESCE(current_setting('app.suppress_schedule_exception', true), '') <> '' THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: vlag overleefde de COMMIT — waarde: %',
                    current_setting('app.suppress_schedule_exception', true);
  END IF;
  RAISE NOTICE 'GEVAL 1 geslaagd: vlag geldt alleen binnen de eigen transactie.';
END;
$$;


-- ════════════════════════════════════════════════════════════════════════
-- GEVAL 2 t/m 5 — gedrag van trigger en RPC (eindigt op ROLLBACK)
-- ════════════════════════════════════════════════════════════════════════
BEGIN;

DO $$
DECLARE
  v_planner  UUID;
  v_pharmacy TEXT;
  v_schedule UUID;
  v_shift    UUID;
  v_d1 DATE := current_date + 7;
  v_d2 DATE := current_date + 14;
  v_d3 DATE := current_date + 21;
  v_d4 DATE := current_date + 28;
  v_d5 DATE := current_date + 35;
  v_d6 DATE := current_date + 42;
  v_before  INT;
  v_after   INT;
  v_deleted INT;
BEGIN
  -- ── Voorbereiding ────────────────────────────────────────────────────
  SELECT id INTO v_planner FROM public.user_profiles
   WHERE role IN ('superuser', 'supervisor', 'admin') LIMIT 1;
  IF v_planner IS NULL THEN
    RAISE EXCEPTION 'OPZET: geen planner in user_profiles — de RPC-guard is niet te passeren.';
  END IF;

  SELECT id INTO v_pharmacy FROM public.pharmacies LIMIT 1;
  IF v_pharmacy IS NULL THEN
    RAISE EXCEPTION 'OPZET: geen apotheek in pharmacies — geen roosterregel aan te maken.';
  END IF;

  -- Doe ons voor als die planner, zodat is_privileged() in de RPC true geeft.
  -- Beide vormen, omdat auth.uid() afhankelijk van de Supabase-versie de losse
  -- claim of de JSON-claims leest. is_local => true: verdwijnt bij de rollback.
  PERFORM set_config('request.jwt.claim.sub', v_planner::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_planner, 'role', 'authenticated')::text, true);
  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'OPZET: impersonatie mislukt — is_privileged() geeft false.';
  END IF;

  -- Testroosterregel. is_active = false zodat de generator hem hoe dan ook negeert.
  INSERT INTO public.pharmacy_schedules
    (pharmacy_id, weekday, start_time, start_date, is_active)
  VALUES (v_pharmacy, 1, '09:00', current_date, false)
  RETURNING id INTO v_schedule;

  -- Vijf concepten + één bevestigde dienst, allemaal in de toekomst.
  INSERT INTO public.shifts (shift_type, shift_date, start_time, status, schedule_id)
  VALUES ('regular', v_d1, '09:00', 'draft',   v_schedule),
         ('regular', v_d2, '09:00', 'draft',   v_schedule),
         ('regular', v_d3, '09:00', 'draft',   v_schedule),
         ('regular', v_d4, '09:00', 'draft',   v_schedule),
         ('regular', v_d5, '09:00', 'draft',   v_schedule),
         ('regular', v_d6, '09:00', 'planned', v_schedule);

  -- ── GEVAL 2: rauwe SQL-delete → exception WORDT vastgelegd ───────────
  -- Precies het pad dat vóór 010 niet gedekt was: geen app, geen RPC.
  DELETE FROM public.shifts WHERE schedule_id = v_schedule AND shift_date = v_d1;

  IF NOT EXISTS (SELECT 1 FROM public.schedule_exceptions
                  WHERE schedule_id = v_schedule AND exception_date = v_d1) THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: rauwe delete op % legde GEEN exception vast.', v_d1;
  END IF;
  RAISE NOTICE 'GEVAL 2 geslaagd: rauwe delete legde een exception vast op %.', v_d1;

  -- ── GEVAL 3: RPC → concepten weg, GEEN exception ─────────────────────
  SELECT count(*) INTO v_before FROM public.schedule_exceptions WHERE schedule_id = v_schedule;

  SELECT public.remove_future_schedule_drafts(v_schedule) INTO v_deleted;

  IF v_deleted <> 4 THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: RPC verwijderde % concepten, verwacht 4.', v_deleted;
  END IF;

  IF EXISTS (SELECT 1 FROM public.shifts
              WHERE schedule_id = v_schedule AND status = 'draft') THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: er staan nog concepten na de RPC.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.shifts
                  WHERE schedule_id = v_schedule AND shift_date = v_d6) THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: de bevestigde dienst op % is meeverwijderd.', v_d6;
  END IF;

  SELECT count(*) INTO v_after FROM public.schedule_exceptions WHERE schedule_id = v_schedule;
  IF v_after <> v_before THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: RPC liet % nieuwe exception(s) achter (was %, nu %).',
                    v_after - v_before, v_before, v_after;
  END IF;
  RAISE NOTICE 'GEVAL 3 geslaagd: RPC ruimde 4 concepten op zonder exception; bevestigde dienst staat er nog.';

  -- ── GEVAL 4: geen meelift na de RPC, binnen dezelfde transactie ──────
  -- De RPC wist de vlag direct na zijn deletes; een volgende delete in DEZELFDE
  -- transactie moet dus weer gewoon een exception opleveren.
  INSERT INTO public.shifts (shift_type, shift_date, start_time, status, schedule_id)
  VALUES ('regular', v_d2, '09:00', 'draft', v_schedule) RETURNING id INTO v_shift;

  DELETE FROM public.shifts WHERE id = v_shift;

  IF NOT EXISTS (SELECT 1 FROM public.schedule_exceptions
                  WHERE schedule_id = v_schedule AND exception_date = v_d2) THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: vlag werkte na de RPC nog door — delete op % onderdrukt.', v_d2;
  END IF;
  RAISE NOTICE 'GEVAL 4 geslaagd: geen meelift op de vlag na de RPC.';

  -- ── GEVAL 5: vlagwaarde uit een andere transactie onderdrukt niets ───
  -- Dit is het scenario dat een booleaanse 'on' NIET zou overleven: een waarde
  -- die om welke reden dan ook blijft staan. '1' is een transactie-id van lang
  -- geleden — precies hoe een gelekte waarde er van hieruit uitziet.
  PERFORM set_config('app.suppress_schedule_exception', '1', true);

  INSERT INTO public.shifts (shift_type, shift_date, start_time, status, schedule_id)
  VALUES ('regular', v_d3, '09:00', 'draft', v_schedule) RETURNING id INTO v_shift;

  DELETE FROM public.shifts WHERE id = v_shift;

  IF NOT EXISTS (SELECT 1 FROM public.schedule_exceptions
                  WHERE schedule_id = v_schedule AND exception_date = v_d3) THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: een vreemde vlagwaarde onderdrukte de exception op %.', v_d3;
  END IF;
  RAISE NOTICE 'GEVAL 5 geslaagd: vlag uit een andere transactie onderdrukt niets.';

  RAISE NOTICE 'ALLE GEVALLEN GESLAAGD — de ROLLBACK hierna draait de testdata terug.';
END;
$$;

ROLLBACK;
