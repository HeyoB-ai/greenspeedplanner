-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 033: de telling achter de badge op Financieel
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 033 eerst (of proefdraai 033 met ROLLBACK en daarna dit).
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: één transactie die op ROLLBACK eindigt.
--
-- De test meet in VERSCHILLEN ten opzichte van de beginstand. De database is
-- gedeeld en er staan al declaraties en meldingen in; een test die absolute
-- getallen verwacht zou morgen falen zonder dat er iets stuk is.
--
-- WAT DE TEST DEKT
--   1. Een ingediende declaratie telt mee
--   2. Een openstaande declaratie telt NIET mee — die ligt bij de koerier
--   3. Een nieuwe meerwerkmelding telt mee
--   4. Een vrijgegeven melding telt NIET mee — die ligt bij de apotheek
--   5. total is de som van de twee
--   6. Een koerier krijgt nullen te zien, geen werkvoorraad van de planner
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.test_033_shift(
  p_courier UUID, p_pharmacy TEXT, p_day DATE, p_start TIME, p_status TEXT
)
RETURNS UUID
LANGUAGE plpgsql AS $helper$
DECLARE v_shift UUID;
BEGIN
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time,
                             budgeted_end_time, status, transport_mode)
  VALUES (p_courier, 'regular', p_day, p_start, p_start + INTERVAL '2 hours',
          'planned', 'bike')
  RETURNING id INTO v_shift;

  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id, budgeted_minutes)
  VALUES (v_shift, p_pharmacy, 120);

  INSERT INTO public.shift_declarations (
    shift_id, courier_id, status, token_hash, token_expires_at)
  VALUES (v_shift, p_courier, p_status,
          public.declaration_hash_token('t-033-' || v_shift::TEXT),
          now() + INTERVAL '30 days');

  RETURN v_shift;
END;
$helper$;

DO $$
DECLARE
  v_planner   UUID;
  v_courier   UUID;
  v_pharmacy  TEXT;
  v_day       DATE := current_date - 9;
  v_submitted UUID;
  v_open      UUID;
  v_base      RECORD;
  v_now       RECORD;
BEGIN
  SELECT id INTO v_planner FROM public.user_profiles
   WHERE role IN ('superuser','supervisor','admin') ORDER BY id LIMIT 1;
  IF v_planner IS NULL THEN RAISE EXCEPTION 'OPZET: geen planner in user_profiles.'; END IF;
  SELECT id INTO v_courier FROM public.user_profiles WHERE role = 'courier' ORDER BY id LIMIT 1;
  IF v_courier IS NULL THEN RAISE EXCEPTION 'OPZET: geen koerier in user_profiles.'; END IF;
  SELECT id INTO v_pharmacy FROM public.pharmacies ORDER BY id LIMIT 1;
  IF v_pharmacy IS NULL THEN RAISE EXCEPTION 'OPZET: geen apotheek.'; END IF;

  PERFORM set_config('request.jwt.claim.sub', v_planner::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_planner, 'role', 'authenticated')::text, true);

  SELECT * INTO v_base FROM public.planner_attention();

  -- ══ OPZET ═══════════════════════════════════════════════════════════
  -- Vier rijen: van elk soort één die moet meetellen en één die dat niet mag.
  v_submitted := public.test_033_shift(v_courier, v_pharmacy, v_day, '08:00', 'submitted');
  v_open      := public.test_033_shift(v_courier, v_pharmacy, v_day, '13:00', 'open');

  INSERT INTO public.extra_work (shift_id, pharmacy_id, planned_minutes,
                                 actual_minutes, extra_minutes, share_pct,
                                 share_minutes, status)
  VALUES (v_submitted, v_pharmacy, 120, 150, 30, 100, 30, 'new'),
         (v_open,      v_pharmacy, 120, 150, 30, 100, 30, 'released');

  SELECT * INTO v_now FROM public.planner_attention();

  -- ══ GEVAL 1 + 2: declaraties ════════════════════════════════════════
  IF v_now.declarations_to_review <> v_base.declarations_to_review + 1 THEN
    RAISE EXCEPTION 'GEVAL 1/2 GEFAALD: declaraties gingen van % naar %, verwacht +1. Eén ingediende telt mee, één openstaande niet.',
      v_base.declarations_to_review, v_now.declarations_to_review;
  END IF;
  RAISE NOTICE 'GEVAL 1 en 2 geslaagd: alleen de ingediende declaratie telt mee.';

  -- ══ GEVAL 3 + 4: meerwerk ═══════════════════════════════════════════
  IF v_now.extra_work_to_release <> v_base.extra_work_to_release + 1 THEN
    RAISE EXCEPTION 'GEVAL 3/4 GEFAALD: meerwerk ging van % naar %, verwacht +1. Een vrijgegeven melding ligt bij de apotheek en hoort niet in de werkvoorraad.',
      v_base.extra_work_to_release, v_now.extra_work_to_release;
  END IF;
  RAISE NOTICE 'GEVAL 3 en 4 geslaagd: alleen de nog niet vrijgegeven melding telt mee.';

  -- ══ GEVAL 5: het totaal ═════════════════════════════════════════════
  IF v_now.total <> v_now.declarations_to_review + v_now.extra_work_to_release THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: total is %, maar de delen zijn % en %.',
      v_now.total, v_now.declarations_to_review, v_now.extra_work_to_release;
  END IF;
  RAISE NOTICE 'GEVAL 5 geslaagd: het getal op de badge is de som van de twee.';

  -- ══ GEVAL 6: een koerier telt niets ═════════════════════════════════
  -- De functie is SECURITY DEFINER en leest twee dichte tabellen. Zonder de
  -- is_privileged()-voorwaarde zou iedereen die inlogt de werkvoorraad zien.
  PERFORM set_config('request.jwt.claim.sub', v_courier::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_courier, 'role', 'authenticated')::text, true);

  SELECT * INTO v_now FROM public.planner_attention();
  IF v_now.total <> 0 OR v_now.declarations_to_review <> 0 OR v_now.extra_work_to_release <> 0 THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: een koerier krijgt % te zien in plaats van nullen.', v_now.total;
  END IF;
  RAISE NOTICE 'GEVAL 6 geslaagd: buiten de planners telt de functie niets.';

  RAISE NOTICE 'ALLE GEVALLEN GESLAAGD.';
END;
$$;

ROLLBACK;   -- niets van deze test blijft staan
