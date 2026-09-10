-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 042: vastgelopen post in de aandachtstelling
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 042 eerst (of proefdraai 042 met ROLLBACK en daarna dit).
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: één transactie die op ROLLBACK eindigt.
--
-- De test meet in VERSCHILLEN. De database is gedeeld en er staat al post in;
-- absolute getallen zouden morgen falen zonder dat er iets stuk is.
--
-- Deze test raakt public.shifts niet aan en heeft dus niets te maken met de
-- trigger shifts_no_past_insert() waar 036 en 037 op struikelden.
--
-- ⚠ DE TEST SIMULEERT EERST EEN PLANNERSESSIE
--   planner_attention() is SECURITY DEFINER en heeft in elke tak de voorwaarde
--   public.is_privileged(). Die functie kijkt naar auth.uid(), en in de SQL Editor
--   is die leeg — dus zonder voorbereiding geeft de functie nullen terug en zou de
--   test op zijn eigen afscherming struikelen in plaats van op de telling. Dat is
--   precies waarop tests/039 faalde.
--
--   Oplossing is het patroon uit de tests van 033 en 034: request.jwt.claim.sub en
--   request.jwt.claims zetten met set_config(..., true), zodat auth.uid() de id van
--   een planner teruggeeft. is_local = true, dus het geldt alleen binnen deze
--   transactie en verdwijnt met de ROLLBACK. Beide instellingen worden gezet omdat
--   auth.uid() ze in die volgorde probeert.
--
-- WAT DE TEST DEKT
--   1. Beide kolommen kloppen met de rechtstreekse telling
--   2. Een failed-rij verhoogt mail_failed met 1 en mail_expired niet
--   3. Een expired-rij verhoogt mail_expired met 1 en mail_failed niet
--   4. total beweegt bij geen van beide mee — die badge gaat over geld
--   5. Een pending- en een sending-rij tellen NIET mee; 'sending' hoort er
--      buiten te blijven omdat hij tijdens elke run legitiem voorkomt
--   6. De vier bestaande kolommen en couriers_without_phone blijven ongemoeid
--   7. De afscherming werkt: een koerierssessie krijgt nullen te zien in plaats
--      van de werkvoorraad van de planner
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
  v_planner UUID;
  v_courier UUID;
  v_start   RECORD;
  v_now     RECORD;
  v_f       INT;
  v_e       INT;
BEGIN
  SELECT id INTO v_courier FROM public.user_profiles WHERE role = 'courier' ORDER BY id LIMIT 1;
  IF v_courier IS NULL THEN RAISE EXCEPTION 'OPZET: geen koerier in user_profiles.'; END IF;

  -- Zonder deze twee regels geeft is_privileged() false en dus alles nul; zie de kop.
  SELECT id INTO v_planner FROM public.user_profiles
   WHERE role IN ('superuser', 'supervisor', 'admin') ORDER BY id LIMIT 1;
  IF v_planner IS NULL THEN RAISE EXCEPTION 'OPZET: geen planner in user_profiles.'; END IF;

  PERFORM set_config('request.jwt.claim.sub', v_planner::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_planner, 'role', 'authenticated')::text, true);

  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'OPZET: is_privileged() geeft nog false na het zetten van de '
                    'jwt-claims. Zonder plannersessie meet deze test niets.';
  END IF;

  SELECT * INTO v_start FROM public.planner_attention();

  -- ── 1. De kolommen kloppen met de rechtstreekse telling ────────────────
  SELECT count(*) FILTER (WHERE status = 'failed')::INT,
         count(*) FILTER (WHERE status = 'expired')::INT
    INTO v_f, v_e
  FROM public.mail_outbox;

  IF v_start.mail_failed IS DISTINCT FROM v_f THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: mail_failed zegt %, de rechtstreekse telling %.',
                    v_start.mail_failed, v_f;
  END IF;
  IF v_start.mail_expired IS DISTINCT FROM v_e THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: mail_expired zegt %, de rechtstreekse telling %.',
                    v_start.mail_expired, v_e;
  END IF;

  -- ── 2. Een mislukte rij ────────────────────────────────────────────────
  INSERT INTO public.mail_outbox (courier_id, kind, payload, status, error)
  VALUES (v_courier, 'shift_confirmed', jsonb_build_object('shifts', '[]'::jsonb),
          'failed', 'Brevo 429: too many requests');

  SELECT * INTO v_now FROM public.planner_attention();
  IF v_now.mail_failed <> v_start.mail_failed + 1 THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: mail_failed ging van % naar %, verwacht %.',
                    v_start.mail_failed, v_now.mail_failed, v_start.mail_failed + 1;
  END IF;
  IF v_now.mail_expired <> v_start.mail_expired THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: mail_expired bewoog mee met een failed-rij. De twee '
                    'tellers moeten los blijven — de verhouding tussen die twee wijst de '
                    'oorzaak aan.';
  END IF;

  -- ── 4a. total blijft staan ─────────────────────────────────────────────
  IF v_now.total <> v_start.total THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: total ging van % naar % door vastgelopen post. De badge '
                    'op Financieel gaat over geld.', v_start.total, v_now.total;
  END IF;

  -- ── 3. Een verlopen rij ────────────────────────────────────────────────
  INSERT INTO public.mail_outbox (courier_id, kind, payload, status, error)
  VALUES (v_courier, 'shift_followup',
          jsonb_build_object('shift_date', (current_date - 30)::TEXT),
          'expired', 'dienst is ouder dan 4 dagen');

  SELECT * INTO v_now FROM public.planner_attention();
  IF v_now.mail_expired <> v_start.mail_expired + 1 THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: mail_expired ging van % naar %, verwacht %.',
                    v_start.mail_expired, v_now.mail_expired, v_start.mail_expired + 1;
  END IF;
  IF v_now.mail_failed <> v_start.mail_failed + 1 THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: mail_failed veranderde door een expired-rij.';
  END IF;

  -- ── 4b. total nog steeds ───────────────────────────────────────────────
  IF v_now.total <> v_start.total THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: total bewoog mee met een expired-rij.';
  END IF;

  -- ── 5. pending en sending tellen niet mee ──────────────────────────────
  -- 'sending' hoort er buiten te blijven: tijdens elke verzendronde staan er
  -- legitiem rijen op die status, en meetellen zou bij elke run een valse melding
  -- geven.
  INSERT INTO public.mail_outbox (courier_id, kind, payload, status)
  VALUES (v_courier, 'shift_confirmed', jsonb_build_object('shifts', '[]'::jsonb), 'pending'),
         (v_courier, 'shift_confirmed', jsonb_build_object('shifts', '[]'::jsonb), 'sending');

  SELECT * INTO v_now FROM public.planner_attention();
  IF v_now.mail_failed <> v_start.mail_failed + 1
     OR v_now.mail_expired <> v_start.mail_expired + 1 THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: een pending- of sending-rij is meegeteld (failed %, '
                    'expired %).', v_now.mail_failed, v_now.mail_expired;
  END IF;

  -- ── 6. De rest is ongemoeid ────────────────────────────────────────────
  IF v_now.declarations_to_review IS DISTINCT FROM v_start.declarations_to_review
     OR v_now.declarations_disputed IS DISTINCT FROM v_start.declarations_disputed
     OR v_now.extra_work_to_release IS DISTINCT FROM v_start.extra_work_to_release
     OR v_now.extra_work_disputed  IS DISTINCT FROM v_start.extra_work_disputed
     OR v_now.couriers_without_phone IS DISTINCT FROM v_start.couriers_without_phone THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: een van de bestaande tellingen is veranderd terwijl er '
                    'alleen post is toegevoegd.';
  END IF;

  -- ── 7. De afscherming ──────────────────────────────────────────────────
  -- Omschakelen naar een koerierssessie. Zonder de is_privileged()-voorwaarde in
  -- elke tak zou een koerier hier kunnen zien hoeveel post er is vastgelopen.
  PERFORM set_config('request.jwt.claim.sub', v_courier::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_courier, 'role', 'authenticated')::text, true);

  IF public.is_privileged() THEN
    RAISE EXCEPTION 'OPZET: is_privileged() geeft true onder een koerierssessie. Geval 7 '
                    'meet dan niets — controleer de rol van %.', v_courier;
  END IF;

  SELECT * INTO v_now FROM public.planner_attention();
  IF v_now.mail_failed <> 0 OR v_now.mail_expired <> 0 OR v_now.total <> 0 THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: een koerierssessie ziet mail_failed = %, mail_expired = % '
                    'en total = %, verwacht drie nullen.',
                    v_now.mail_failed, v_now.mail_expired, v_now.total;
  END IF;

  RAISE NOTICE 'Alle 7 gevallen geslaagd.';
END $$;

-- ────────────────────────────────────────────────────────────────────────
-- Stand na afloop, ter controle vóór de rollback.
-- ────────────────────────────────────────────────────────────────────────
SELECT * FROM public.planner_attention();

ROLLBACK;   -- er blijft niets van deze test achter
