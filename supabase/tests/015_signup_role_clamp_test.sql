-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 015: registratie levert altijd een koerier op
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 015 eerst (of proefdraai 015 met ROLLBACK en daarna dit).
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: één transactie die op ROLLBACK eindigt — ook de
-- testrijen in auth.users. De WARNINGs die je onderweg ziet ([rol-clamp] …)
-- horen erbij: dat is de clamp die meldt dat hij iets heeft teruggezet.
--
-- De test schrijft rechtstreeks in auth.users, want dát is wat een signUp doet
-- en de trigger is het enige dat we willen beproeven. De kolomlijst van die
-- tabel verschilt per Supabase-versie; lukt de eerste insert niet, dan stopt de
-- test met een OPZET-melding in plaats van stilzwijgend te slagen.
--
-- WAT DE TEST DEKT
--   1. metadata role=superuser  → profiel wordt courier      ← de kern
--   2. metadata role=courier    → profiel wordt courier
--   3. metadata met pharmacy_ids→ niet overgenomen (leeg)
--   4. geen rol in de metadata  → GEEN profiel (het pad voor accounts die je
--                                 zelf in het dashboard aanmaakt)
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
  v_super  UUID := gen_random_uuid();
  v_koer   UUID := gen_random_uuid();
  v_leeg   UUID := gen_random_uuid();
  v_role   TEXT;
  v_phs    TEXT[];
  v_count  INT;
  v_state  TEXT;
  v_msg    TEXT;
BEGIN
  -- ── GEVAL 1: signUp met role=superuser in de metadata ────────────────
  -- Dit is het gat uit migratie 002: met alleen de anon-key een superuser maken.
  BEGIN
    INSERT INTO auth.users (
      id, instance_id, aud, role, email, encrypted_password,
      created_at, updated_at, raw_app_meta_data, raw_user_meta_data
    ) VALUES (
      v_super, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
      'clamp-super@example.com', '', now(), now(), '{}'::jsonb,
      jsonb_build_object('name', 'Clamp Super', 'role', 'superuser')
    );
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    RAISE EXCEPTION 'OPZET: kon geen testrij in auth.users maken (% — %). Zonder die rij is de trigger niet te beproeven; pas de kolomlijst hierboven aan op deze Supabase-versie.', v_state, v_msg;
  END;

  SELECT role INTO v_role FROM public.user_profiles WHERE id = v_super;
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: de trigger maakte helemaal geen profiel aan.';
  END IF;
  IF v_role <> 'courier' THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: metadata role=superuser leverde een %-profiel op — het gat staat nog open.', v_role;
  END IF;
  RAISE NOTICE 'GEVAL 1 geslaagd: role=superuser uit de metadata levert een courier op.';

  -- ── GEVAL 2: gewone koeriersregistratie blijft werken ────────────────
  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    created_at, updated_at, raw_app_meta_data, raw_user_meta_data
  ) VALUES (
    v_koer, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
    'clamp-koerier@example.com', '', now(), now(), '{}'::jsonb,
    jsonb_build_object('name', 'Clamp Koerier', 'role', 'courier',
                       'pharmacy_ids', jsonb_build_array('ph-smokkel-1', 'ph-smokkel-2'))
  );

  SELECT role, pharmacy_ids INTO v_role, v_phs FROM public.user_profiles WHERE id = v_koer;
  IF v_role IS DISTINCT FROM 'courier' THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: zelfregistratie gaf % in plaats van courier.', v_role;
  END IF;
  RAISE NOTICE 'GEVAL 2 geslaagd: zelfregistratie levert een courier op.';

  -- ── GEVAL 3: apotheken uit de metadata worden genegeerd ──────────────
  -- pharmacy_ids stuurt toegang aan; die array mag niet door de client te
  -- vullen zijn. De koppelcode is de enige weg.
  IF coalesce(array_length(v_phs, 1), 0) <> 0 THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: pharmacy_ids uit de metadata is overgenomen (%).', v_phs;
  END IF;
  RAISE NOTICE 'GEVAL 3 geslaagd: pharmacy_ids uit de metadata wordt genegeerd.';

  -- ── GEVAL 4: zonder rol in de metadata géén profiel ──────────────────
  -- Dit is het pad voor accounts die je zelf in het dashboard aanmaakt: geen
  -- automatische rij, zodat jij hem daarna met de juiste rol zet.
  INSERT INTO auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    created_at, updated_at, raw_app_meta_data, raw_user_meta_data
  ) VALUES (
    v_leeg, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
    'clamp-handmatig@example.com', '', now(), now(), '{}'::jsonb,
    jsonb_build_object('name', 'Handmatig Account')
  );

  SELECT count(*) INTO v_count FROM public.user_profiles WHERE id = v_leeg;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: zonder rol in de metadata werd toch een profiel aangemaakt — een handmatig account zou dan als koerier binnenkomen.';
  END IF;
  RAISE NOTICE 'GEVAL 4 geslaagd: zonder rol in de metadata geen profiel; de rol zet je zelf.';

  RAISE NOTICE 'ALLE GEVALLEN GESLAAGD — de ROLLBACK hierna draait de testrijen terug.';
END;
$$;

ROLLBACK;
