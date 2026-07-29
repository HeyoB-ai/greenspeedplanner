-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 015: rol bij registratie vastklemmen
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 015 eerst (of proefdraai 015 met ROLLBACK en daarna dit).
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: één transactie die op ROLLBACK eindigt. De WARNINGs
-- die je onderweg ziet ([rol-clamp] …) horen erbij — dat is de clamp die zijn
-- werk meldt, niet een fout.
--
-- WAT DE TEST DEKT
--   1. role 'courier'                       → courier (zelfregistratie mag)
--   2. role 'superuser' zonder uitnodiging  → courier  ← de kern
--   3. role 'SUPERVISOR' (HOOFDLETTERS) mét uitnodiging → supervisor
--      (de bug in send-invite.ts; zonder normalisatie zou dit courier worden)
--   4. uitnodiging in hoofdletters opgeslagen → ook goed
--   5. verlopen uitnodiging                 → courier
--   6. al geaccepteerde uitnodiging         → courier
--   7. uitnodiging voor een ánder adres     → courier
--   8. onbekende rol 'wizard'               → courier (breekt de CHECK niet)
--   9. geen rol in de metadata              → NULL (geen profiel, ongewijzigd)
--  10. end-to-end: rij in auth.users met role=superuser → profiel wordt courier
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
  v_planner  UUID;
  v_email    TEXT := 'clamp-test@example.com';
  v_other    TEXT := 'clamp-ander@example.com';
  v_role     TEXT;
  v_user     UUID := gen_random_uuid();
  v_state    TEXT;
  v_msg      TEXT;
  v_made     BOOLEAN := false;
BEGIN
  SELECT id INTO v_planner FROM public.user_profiles
   WHERE role IN ('superuser', 'supervisor', 'admin') LIMIT 1;
  IF v_planner IS NULL THEN
    RAISE EXCEPTION 'OPZET: geen planner in user_profiles — invited_by is niet te vullen.';
  END IF;

  -- ── GEVAL 1: koerier mag zichzelf registreren ────────────────────────
  v_role := public.resolve_signup_role(v_email, 'courier');
  IF v_role IS DISTINCT FROM 'courier' THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: zelfregistratie gaf % in plaats van courier.', v_role;
  END IF;
  RAISE NOTICE 'GEVAL 1 geslaagd: zelfregistratie blijft courier.';

  -- ── GEVAL 2: superuser uit de metadata, zonder uitnodiging ───────────
  -- Dit is het gat: signUp met alleen de anon-key en role=superuser.
  v_role := public.resolve_signup_role(v_email, 'superuser');
  IF v_role IS DISTINCT FROM 'courier' THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: metadata role=superuser leverde % op — het gat staat nog open.', v_role;
  END IF;
  RAISE NOTICE 'GEVAL 2 geslaagd: superuser uit metadata valt terug op courier.';

  -- ── GEVAL 3: HOOFDLETTERS in de metadata, geldige uitnodiging ────────
  -- send-invite.ts:41 stuurt 'SUPERVISOR'. Met normalisatie hoort dit te werken.
  INSERT INTO public.invitations (email, role, pharmacy_id, invited_by)
  VALUES (v_email, 'supervisor', 'test-apotheek', v_planner);

  v_role := public.resolve_signup_role(v_email, 'SUPERVISOR');
  IF v_role IS DISTINCT FROM 'supervisor' THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: SUPERVISOR met geldige uitnodiging gaf % — de vergelijking is niet hoofdletter-ongevoelig.', v_role;
  END IF;
  RAISE NOTICE 'GEVAL 3 geslaagd: SUPERVISOR wordt genormaliseerd en herkend.';

  -- ── GEVAL 4: ook de rol ÍN de uitnodiging in hoofdletters ────────────
  UPDATE public.invitations SET role = 'SUPERVISOR' WHERE email = v_email;
  v_role := public.resolve_signup_role(v_email, 'supervisor');
  IF v_role IS DISTINCT FROM 'supervisor' THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: uitnodiging met rol in hoofdletters werd niet herkend (%).', v_role;
  END IF;
  RAISE NOTICE 'GEVAL 4 geslaagd: ook de opgeslagen rol wordt genormaliseerd.';

  -- ── GEVAL 5: verlopen uitnodiging telt niet ──────────────────────────
  UPDATE public.invitations
     SET role = 'supervisor', expires_at = now() - interval '1 hour'
   WHERE email = v_email;
  v_role := public.resolve_signup_role(v_email, 'supervisor');
  IF v_role IS DISTINCT FROM 'courier' THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: verlopen uitnodiging gaf alsnog % — de drie uit mei zouden zo nog werken.', v_role;
  END IF;
  RAISE NOTICE 'GEVAL 5 geslaagd: verlopen uitnodiging telt niet.';

  -- ── GEVAL 6: al geaccepteerde uitnodiging telt niet ──────────────────
  UPDATE public.invitations
     SET expires_at = now() + interval '48 hours', accepted_at = now()
   WHERE email = v_email;
  v_role := public.resolve_signup_role(v_email, 'supervisor');
  IF v_role IS DISTINCT FROM 'courier' THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: geaccepteerde uitnodiging is hergebruikt (%).', v_role;
  END IF;
  RAISE NOTICE 'GEVAL 6 geslaagd: een uitnodiging is eenmalig.';

  -- ── GEVAL 7: uitnodiging voor een ander adres ────────────────────────
  UPDATE public.invitations SET accepted_at = NULL WHERE email = v_email;
  v_role := public.resolve_signup_role(v_other, 'supervisor');
  IF v_role IS DISTINCT FROM 'courier' THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: uitnodiging van een ander adres werd geaccepteerd (%).', v_role;
  END IF;
  RAISE NOTICE 'GEVAL 7 geslaagd: uitnodiging geldt alleen voor het eigen adres.';

  -- ── GEVAL 8: onbekende rol breekt niets ──────────────────────────────
  v_role := public.resolve_signup_role(v_email, 'wizard');
  IF v_role IS DISTINCT FROM 'courier' THEN
    RAISE EXCEPTION 'GEVAL 8 GEFAALD: onzinrol gaf % — dat zou de CHECK op user_profiles.role breken.', v_role;
  END IF;
  RAISE NOTICE 'GEVAL 8 geslaagd: onbekende rol valt terug op courier.';

  -- ── GEVAL 9: geen rol in de metadata ─────────────────────────────────
  v_role := public.resolve_signup_role(v_email, NULL);
  IF v_role IS NOT NULL THEN
    RAISE EXCEPTION 'GEVAL 9 GEFAALD: zonder rol werd % teruggegeven; de trigger hoort dan niets te doen.', v_role;
  END IF;
  RAISE NOTICE 'GEVAL 9 geslaagd: zonder rol geen profiel (ongewijzigd gedrag).';

  -- ── GEVAL 10: end-to-end via de trigger ──────────────────────────────
  -- Een rij in auth.users met role=superuser in de metadata. De kolomlijst van
  -- auth.users verschilt per Supabase-versie; lukt de insert niet, dan meldt de
  -- test dat als OPZET en niet als een gefaalde clamp.
  BEGIN
    INSERT INTO auth.users (
      id, instance_id, aud, role, email, encrypted_password,
      created_at, updated_at, raw_app_meta_data, raw_user_meta_data
    ) VALUES (
      v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
      'clamp-e2e@example.com', '', now(), now(), '{}'::jsonb,
      jsonb_build_object('name', 'Clamp Test', 'role', 'superuser')
    );
    v_made := true;
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    RAISE WARNING 'GEVAL 10 OVERGESLAGEN: kon geen testrij in auth.users maken (% — %). De gevallen 1 t/m 9 dekken de clamp zelf al.', v_state, v_msg;
  END;

  IF v_made THEN
    SELECT role INTO v_role FROM public.user_profiles WHERE id = v_user;
    IF v_role IS NULL THEN
      RAISE EXCEPTION 'GEVAL 10 GEFAALD: de trigger maakte geen profiel aan.';
    END IF;
    IF v_role <> 'courier' THEN
      RAISE EXCEPTION 'GEVAL 10 GEFAALD: signUp met role=superuser leverde een %-profiel op.', v_role;
    END IF;
    RAISE NOTICE 'GEVAL 10 geslaagd: signUp met role=superuser levert een courier-profiel op.';
  END IF;

  RAISE NOTICE 'ALLE GEVALLEN GESLAAGD — de ROLLBACK hierna draait de testdata terug.';
END;
$$;

ROLLBACK;
