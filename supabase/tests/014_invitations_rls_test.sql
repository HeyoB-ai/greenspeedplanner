-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 014: RLS op invitations
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Je kunt het draaien VÓÓR 014: de test zet de policies zelf neer binnen zijn
-- eigen transactie. Draai je het ná 014, dan worden dezelfde policies gewoon
-- opnieuw gezet en verandert er niets.
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: alles zit in één transactie die op ROLLBACK eindigt,
-- inclusief de policies die de test zelf zet.
--
-- ┌─ WAAROM SET LOCAL ROLE ────────────────────────────────────────────────┐
-- │ In de SQL Editor draai je als `postgres`, en die rol OMZEILT RLS        │
-- │ volledig. Een test die alleen set_config('request.jwt.claim.sub', …)    │
-- │ doet, slaagt daarom altijd en bewijst niets. Pas na                     │
-- │ `SET LOCAL ROLE authenticated` gelden de policies écht. Dat is het      │
-- │ verschil tussen deze test en een test die je in slaap sust.             │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAT DE TEST DEKT
--   1. Koerier mag GEEN uitnodiging aanmaken (is_privileged-eis)
--   2. Koerier ziet GEEN uitnodigingen — dus ook geen tokens
--   3. Planner mag WEL aanmaken en krijgt de token terug (het pad van
--      authService.inviteUser: insert + .select('token'))
--   4. Planner mag niet aanmaken op naam van een ander (invited_by-eis)
--   5. Planner ziet de uitnodigingen wél
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- ── De policies die getest worden (identiek aan migratie 014) ────────────
DO $$
DECLARE pol record;
BEGIN
  FOR pol IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'invitations'
      AND cmd IN ('SELECT', 'INSERT', 'ALL')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.invitations', pol.policyname);
  END LOOP;
END $$;

ALTER TABLE public.invitations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "uitnodiging aanmaken" ON public.invitations
  FOR INSERT WITH CHECK (auth.uid() = invited_by AND public.is_privileged());

CREATE POLICY "uitnodiging lezen" ON public.invitations
  FOR SELECT USING (auth.uid() = invited_by OR public.is_privileged());


DO $$
DECLARE
  v_courier UUID;
  v_planner UUID;
  v_token   TEXT;
  v_count   INT;
  v_failed  BOOLEAN;
  v_state   TEXT;
  v_msg     TEXT;
BEGIN
  -- ── Voorbereiding (nog als postgres) ─────────────────────────────────
  SELECT id INTO v_courier FROM public.user_profiles WHERE role = 'courier' LIMIT 1;
  IF v_courier IS NULL THEN
    RAISE EXCEPTION 'OPZET: geen koerier in user_profiles — de weigering is niet te toetsen.';
  END IF;

  SELECT id INTO v_planner FROM public.user_profiles
   WHERE role IN ('superuser', 'supervisor', 'admin') LIMIT 1;
  IF v_planner IS NULL THEN
    RAISE EXCEPTION 'OPZET: geen planner in user_profiles — is_privileged() is niet te passeren.';
  END IF;

  -- ══════════════════════════════════════════════════════════════════════
  -- Vanaf hier doen we ons voor als de KOERIER.
  -- Beide claim-vormen, omdat auth.uid() afhankelijk van de Supabase-versie de
  -- losse claim of de JSON-claims leest. is_local => true: verdwijnt bij de
  -- rollback. En dan de rolwissel, want zonder die regel test je niets.
  -- ══════════════════════════════════════════════════════════════════════
  PERFORM set_config('request.jwt.claim.sub', v_courier::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_courier, 'role', 'authenticated')::text, true);
  PERFORM set_config('role', 'authenticated', true);

  -- ── GEVAL 1: koerier mag geen uitnodiging aanmaken ───────────────────
  v_failed := false;
  BEGIN
    INSERT INTO public.invitations (email, role, pharmacy_id, invited_by)
    VALUES ('test-koerier@example.com', 'admin', 'test-apotheek', v_courier);
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state <> '42501' THEN
      RAISE EXCEPTION 'GEVAL 1 ONBRUIKBAAR: insert faalde op iets anders dan RLS (% — %).', v_state, v_msg;
    END IF;
    v_failed := true;
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: een koerier kon een uitnodiging voor rol admin aanmaken.';
  END IF;
  RAISE NOTICE 'GEVAL 1 geslaagd: koerier wordt geweigerd bij het aanmaken.';

  -- ── GEVAL 2: koerier ziet geen uitnodigingen van anderen ─────────────
  -- Precies geformuleerd: rijen die hij zelf zou hebben aangemaakt mag hij zien
  -- (dat is de invited_by-helft van de policy). Alles daarbuiten niet — dát is
  -- de eigenschap die de publieke USING(true) uit migratie 001 weggaf.
  SELECT count(*) INTO v_count FROM public.invitations WHERE invited_by IS DISTINCT FROM v_courier;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: koerier ziet % uitnodiging(en) van anderen — tokens zijn dus leesbaar.', v_count;
  END IF;
  RAISE NOTICE 'GEVAL 2 geslaagd: koerier ziet geen uitnodigingen van anderen.';

  -- ══════════════════════════════════════════════════════════════════════
  -- Vanaf hier doen we ons voor als de PLANNER.
  -- ══════════════════════════════════════════════════════════════════════
  PERFORM set_config('request.jwt.claim.sub', v_planner::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_planner, 'role', 'authenticated')::text, true);

  -- ── GEVAL 3: planner mag aanmaken én de token terugkrijgen ───────────
  -- Precies wat authService.inviteUser doet: insert + returning token.
  INSERT INTO public.invitations (email, role, pharmacy_id, invited_by)
  VALUES ('test-planner@example.com', 'admin', 'test-apotheek', v_planner)
  RETURNING token INTO v_token;

  IF v_token IS NULL OR length(v_token) = 0 THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: geen token teruggekregen — inviteUser zou hier stoppen en geen mail versturen.';
  END IF;
  RAISE NOTICE 'GEVAL 3 geslaagd: planner maakt de uitnodiging aan en leest de token terug.';

  -- ── GEVAL 4: niet op naam van een ander ──────────────────────────────
  v_failed := false;
  BEGIN
    INSERT INTO public.invitations (email, role, pharmacy_id, invited_by)
    VALUES ('test-namens@example.com', 'admin', 'test-apotheek', v_courier);
  EXCEPTION WHEN others THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state <> '42501' THEN
      RAISE EXCEPTION 'GEVAL 4 ONBRUIKBAAR: insert faalde op iets anders dan RLS (% — %).', v_state, v_msg;
    END IF;
    v_failed := true;
  END;
  IF NOT v_failed THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: planner kon een uitnodiging op naam van iemand anders zetten.';
  END IF;
  RAISE NOTICE 'GEVAL 4 geslaagd: invited_by moet de eigen gebruiker zijn.';

  -- ── GEVAL 5: planner ziet uitnodigingen wél ──────────────────────────
  SELECT count(*) INTO v_count FROM public.invitations;
  IF v_count = 0 THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: planner ziet geen enkele uitnodiging, ook niet de zojuist aangemaakte.';
  END IF;
  RAISE NOTICE 'GEVAL 5 geslaagd: planner leest de uitnodigingen (% zichtbaar).', v_count;

  PERFORM set_config('role', 'postgres', true);
  RAISE NOTICE 'ALLE GEVALLEN GESLAAGD — de ROLLBACK hierna draait policies en testdata terug.';
END;
$$;

ROLLBACK;
