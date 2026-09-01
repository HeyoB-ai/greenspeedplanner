-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 034: betwistingen tellen mee in de badge
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 034 eerst (of proefdraai 034 met ROLLBACK en daarna dit).
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
-- OPSTELLING — vier diensten, en per soort van elke status één rij:
--   declaraties  submitted, open, disputed, approved
--   meerwerk     new, released, disputed, expired
--
-- WAT DE TEST DEKT
--   1. Ingediend en betwist tellen mee; open en goedgekeurd niet
--   2. Betwiste declaraties komen apart terug
--   3. Nieuw en betwist meerwerk tellen mee; vrijgegeven en verlopen niet
--   4. Betwist meerwerk komt apart terug
--   5. total is de som van de twee werkvoorraden, niet van alle vier de getallen
--   6. Een koerier krijgt nullen te zien
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.test_034_shift(
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
          public.declaration_hash_token('t-034-' || v_shift::TEXT),
          now() + INTERVAL '30 days');

  RETURN v_shift;
END;
$helper$;

DO $$
DECLARE
  v_planner   UUID;
  v_courier   UUID;
  v_pharmacy  TEXT;
  v_day       DATE := current_date - 11;
  v_s1        UUID;   -- ingediend    / meerwerk nieuw
  v_s2        UUID;   -- open         / meerwerk vrijgegeven
  v_s3        UUID;   -- betwist      / meerwerk betwist
  v_s4        UUID;   -- goedgekeurd  / meerwerk verlopen
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
  v_s1 := public.test_034_shift(v_courier, v_pharmacy, v_day, '08:00', 'submitted');
  v_s2 := public.test_034_shift(v_courier, v_pharmacy, v_day, '11:00', 'open');
  v_s3 := public.test_034_shift(v_courier, v_pharmacy, v_day, '14:00', 'disputed');
  v_s4 := public.test_034_shift(v_courier, v_pharmacy, v_day, '17:00', 'approved');

  INSERT INTO public.extra_work (shift_id, pharmacy_id, planned_minutes,
                                 actual_minutes, extra_minutes, share_pct,
                                 share_minutes, status)
  VALUES (v_s1, v_pharmacy, 120, 150, 30, 100, 30, 'new'),
         (v_s2, v_pharmacy, 120, 150, 30, 100, 30, 'released'),
         (v_s3, v_pharmacy, 120, 150, 30, 100, 30, 'disputed'),
         (v_s4, v_pharmacy, 120, 150, 30, 100, 30, 'expired');

  SELECT * INTO v_now FROM public.planner_attention();

  -- ══ GEVAL 1: declaraties — ingediend én betwist ═════════════════════
  IF v_now.declarations_to_review <> v_base.declarations_to_review + 2 THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: declaraties gingen van % naar %, verwacht +2 (ingediend + betwist). Open ligt bij de koerier, goedgekeurd is klaar.',
      v_base.declarations_to_review, v_now.declarations_to_review;
  END IF;
  RAISE NOTICE 'GEVAL 1 geslaagd: ingediend en betwist tellen mee, open en goedgekeurd niet.';

  -- ══ GEVAL 2: betwiste declaraties apart ═════════════════════════════
  IF v_now.declarations_disputed <> v_base.declarations_disputed + 1 THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: betwiste declaraties gingen van % naar %, verwacht +1.',
      v_base.declarations_disputed, v_now.declarations_disputed;
  END IF;
  RAISE NOTICE 'GEVAL 2 geslaagd: een betwisting komt apart terug.';

  -- ══ GEVAL 3: meerwerk — nieuw én betwist ════════════════════════════
  IF v_now.extra_work_to_release <> v_base.extra_work_to_release + 2 THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: meerwerk ging van % naar %, verwacht +2 (nieuw + betwist). Vrijgegeven ligt bij de apotheek, verlopen is factureerbaar.',
      v_base.extra_work_to_release, v_now.extra_work_to_release;
  END IF;
  RAISE NOTICE 'GEVAL 3 geslaagd: nieuw en betwist tellen mee, vrijgegeven en verlopen niet.';

  -- ══ GEVAL 4: betwist meerwerk apart ═════════════════════════════════
  IF v_now.extra_work_disputed <> v_base.extra_work_disputed + 1 THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: betwist meerwerk ging van % naar %, verwacht +1.',
      v_base.extra_work_disputed, v_now.extra_work_disputed;
  END IF;
  RAISE NOTICE 'GEVAL 4 geslaagd: een betwisting door de apotheek komt apart terug.';

  -- ══ GEVAL 5: het totaal ═════════════════════════════════════════════
  -- De betwiste getallen zitten al IN de twee werkvoorraden; ze mogen er niet
  -- nog een keer bij opgeteld worden, anders telt de badge dubbel.
  IF v_now.total <> v_now.declarations_to_review + v_now.extra_work_to_release THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: total is %, maar de twee werkvoorraden zijn % en %. Betwist telt apart mee terug, niet er bovenop.',
      v_now.total, v_now.declarations_to_review, v_now.extra_work_to_release;
  END IF;
  RAISE NOTICE 'GEVAL 5 geslaagd: het getal op de badge telt niets dubbel.';

  -- ══ GEVAL 6: een koerier telt niets ═════════════════════════════════
  PERFORM set_config('request.jwt.claim.sub', v_courier::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_courier, 'role', 'authenticated')::text, true);

  SELECT * INTO v_now FROM public.planner_attention();
  IF v_now.total <> 0 OR v_now.declarations_to_review <> 0 OR v_now.extra_work_to_release <> 0
     OR v_now.declarations_disputed <> 0 OR v_now.extra_work_disputed <> 0 THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: een koerier krijgt % te zien in plaats van nullen.', v_now.total;
  END IF;
  RAISE NOTICE 'GEVAL 6 geslaagd: buiten de planners telt de functie niets.';

  RAISE NOTICE 'ALLE GEVALLEN GESLAAGD.';
END;
$$;

ROLLBACK;   -- niets van deze test blijft staan
