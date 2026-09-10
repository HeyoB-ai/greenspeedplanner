-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 039: koeriers zonder telefoonnummer in de badge
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 039 eerst (of proefdraai 039 met ROLLBACK en daarna dit).
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: één transactie die op ROLLBACK eindigt. Dat geldt ook
-- voor het weghalen en terugzetten van een contactrij in geval 2 en 3.
--
-- De test meet in VERSCHILLEN. De database is gedeeld en er staan al koeriers met
-- én zonder nummer in; een test die absolute getallen verwacht zou morgen falen
-- zonder dat er iets stuk is.
--
-- WAT DE TEST DEKT
--   1. De kolom bestaat en klopt met de rechtstreekse telling
--   2. Een nummer weghalen laat de telling met precies 1 stijgen
--   3. Een nummer terugzetten laat hem met precies 1 dalen
--   4. total verandert NIET mee — de badge op Financieel gaat over geld
--   5. De vier bestaande kolommen tellen nog zoals in 033/034
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
  v_courier UUID;
  v_phone   TEXT;
  v_note    TEXT;
  v_had     BOOLEAN;
  v_start   RECORD;
  v_now     RECORD;
  v_direct  INT;
BEGIN
  SELECT * INTO v_start FROM public.planner_attention();

  -- ── 1. De kolom klopt met de rechtstreekse telling ─────────────────────
  SELECT count(*)::INT INTO v_direct
  FROM public.user_profiles up
  LEFT JOIN public.courier_contacts cc ON cc.courier_id = up.id
  WHERE up.role = 'courier' AND cc.courier_id IS NULL;

  IF v_start.couriers_without_phone IS DISTINCT FROM v_direct THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: de badge zegt %, de rechtstreekse telling %.',
                    v_start.couriers_without_phone, v_direct;
  END IF;

  -- ── Opzet voor 2 en 3: een koerier die NU een nummer heeft ─────────────
  SELECT cc.courier_id, cc.phone_e164, cc.note
    INTO v_courier, v_phone, v_note
  FROM public.courier_contacts cc
  JOIN public.user_profiles up ON up.id = cc.courier_id
  WHERE up.role = 'courier'
  ORDER BY cc.courier_id
  LIMIT 1;

  v_had := v_courier IS NOT NULL;
  IF NOT v_had THEN
    RAISE NOTICE 'GEVAL 2 en 3 OVERGESLAGEN: geen enkele koerier heeft een nummer, '
                 'dus er is niets weg te halen. Vul eerst een nummer in.';
  ELSE
    -- ── 2. Weghalen → één meer zonder nummer ─────────────────────────────
    DELETE FROM public.courier_contacts WHERE courier_id = v_courier;
    SELECT * INTO v_now FROM public.planner_attention();

    IF v_now.couriers_without_phone <> v_start.couriers_without_phone + 1 THEN
      RAISE EXCEPTION 'GEVAL 2 GEFAALD: na het weghalen van één nummer staat de telling op % '
                      '(was %), verwacht % — de badge volgt de gegevens niet.',
                      v_now.couriers_without_phone, v_start.couriers_without_phone,
                      v_start.couriers_without_phone + 1;
    END IF;

    -- ── 4. total mag NIET meebewegen ─────────────────────────────────────
    IF v_now.total <> v_start.total THEN
      RAISE EXCEPTION 'GEVAL 4 GEFAALD: total ging van % naar % door een ontbrekend nummer. '
                      'De badge op Financieel gaat over geld; een gat in de gegevens hoort '
                      'daar niet bij op te tellen.', v_start.total, v_now.total;
    END IF;

    -- ── 3. Terugzetten → weer terug op de beginstand ─────────────────────
    INSERT INTO public.courier_contacts (courier_id, phone_e164, note)
    VALUES (v_courier, v_phone, v_note);
    SELECT * INTO v_now FROM public.planner_attention();

    IF v_now.couriers_without_phone <> v_start.couriers_without_phone THEN
      RAISE EXCEPTION 'GEVAL 3 GEFAALD: na terugzetten staat de telling op % in plaats van %.',
                      v_now.couriers_without_phone, v_start.couriers_without_phone;
    END IF;
  END IF;

  -- ── 5. De bestaande kolommen zijn ongemoeid ────────────────────────────
  SELECT * INTO v_now FROM public.planner_attention();
  IF v_now.declarations_to_review IS DISTINCT FROM v_start.declarations_to_review
     OR v_now.declarations_disputed IS DISTINCT FROM v_start.declarations_disputed
     OR v_now.extra_work_to_release IS DISTINCT FROM v_start.extra_work_to_release
     OR v_now.extra_work_disputed  IS DISTINCT FROM v_start.extra_work_disputed
     OR v_now.total                IS DISTINCT FROM v_start.total THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: een van de vier bestaande tellingen of total is veranderd '
                    'terwijl er alleen aan nummers is gesleuteld.';
  END IF;

  IF v_now.total <> v_now.declarations_to_review + v_now.extra_work_to_release THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: total (%) is niet de som van declaraties (%) en meerwerk (%).',
                    v_now.total, v_now.declarations_to_review, v_now.extra_work_to_release;
  END IF;

  RAISE NOTICE 'Alle gevallen geslaagd (2 en 3 mogelijk overgeslagen, zie eventuele NOTICE).';
END $$;

-- ────────────────────────────────────────────────────────────────────────
-- Stand na afloop, ter controle vóór de rollback.
-- ────────────────────────────────────────────────────────────────────────
SELECT * FROM public.planner_attention();

ROLLBACK;   -- er blijft niets van deze test achter
