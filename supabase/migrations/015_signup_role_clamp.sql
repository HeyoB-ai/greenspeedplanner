-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed — rol bij registratie vastklemmen — migratie 015
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 014 eerst: deze migratie gebruikt invitations als betrouwbare
-- bron, en dat is die tabel pas als niet iedereen erin kan schrijven.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien, en draai daarna       │
-- │ supabase/tests/015_signup_role_clamp_test.sql.                          │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAT ER MIS IS
-- handle_new_user() (migratie 002 van de bezorg-app) neemt de rol letterlijk
-- over uit new.raw_user_meta_data->>'role'. Die metadata komt uit de browser:
--   supabase.auth.signUp({ options: { data: { role: 'superuser' } } })
-- met alleen de anon-key is genoeg voor een superuser-profiel. Geen account
-- nodig, geen RLS die het tegenhoudt — de trigger draait als SECURITY DEFINER.
--
-- WAT DEZE MIGRATIE DOET
-- De rol wordt niet meer geloofd maar afgeleid:
--   * 'courier'                → altijd toegestaan (zelfregistratie)
--   * een andere rol           → alleen met een openstaande, niet-verlopen
--                                uitnodiging voor hetzelfde e-mailadres
--   * al het overige           → valt terug op 'courier', met een WARNING in de
--                                Postgres-logs zodat het niet onzichtbaar is
-- Nooit verheffen, alleen terugvallen. Ook pharmacy_ids komt niet langer uit de
-- metadata maar uit de uitnodiging: die array stuurt toegang aan
-- (utils/pharmacyAccess.ts in de bezorg-app) en was net zo goed door de client
-- te vullen.
--
-- HOOFDLETTERS
-- send-invite.ts:41 stuurt de rol als 'SUPERVISOR', terwijl user_profiles.role
-- alleen kleine letters toestaat. De vergelijking hieronder normaliseert daarom
-- beide kanten (lower + btrim): de metadata én de rol in de uitnodiging. Zonder
-- die normalisatie zou een correcte uitnodiging alsnog op 'courier' uitkomen
-- zodra die bug in de bezorg-app gerepareerd wordt.
--
-- ┌─ LET OP — GEDRAGSVERANDERING ──────────────────────────────────────────┐
-- │ Vandaag faalt de superuser-uitnodigingsflow hard: 'SUPERVISOR' botst op │
-- │ de CHECK op user_profiles.role, de trigger breekt en er komt géén        │
-- │ gebruiker. Ná deze migratie wordt die rol genormaliseerd naar            │
-- │ 'supervisor'; is er geen bijbehorende uitnodigingsrij (en die is er in    │
-- │ die flow niet — UserManagementPanel.tsx:105 schrijft naar kolommen die   │
-- │ niet bestaan), dan komt de uitgenodigde binnen als KOERIER in plaats van │
-- │ dat het misgaat. Stil verkeerd in plaats van luid stuk.                  │
-- │                                                                          │
-- │ Het blijft zichtbaar via de WARNING in de logs, en het is opgelost zodra │
-- │ de twee bezorg-app-punten gefixt zijn (rol in kleine letters + de        │
-- │ tracking-insert). Wil je in de tussentijd liever een harde fout, vervang │
-- │ dan in resolve_signup_role() de laatste `RETURN 'courier';` door         │
-- │ `RAISE EXCEPTION`. Veiligheidstechnisch maakt het niets uit — in beide    │
-- │ gevallen ontstaat er geen verhoogde rol.                                 │
-- └──────────────────────────────────────────────────────────────────────────┘
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────
-- 1. resolve_signup_role — de beslissing, apart en toetsbaar.
--    Bewust een eigen functie en niet inline in de trigger: zo is elk geval
--    los te beproeven zonder een rij in auth.users te hoeven maken.
--    Geeft NULL terug als er geen rol in de metadata stond; de trigger laat de
--    registratie dan met rust (ongewijzigd gedrag t.o.v. migratie 002).
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.resolve_signup_role(p_email TEXT, p_meta_role TEXT)
RETURNS TEXT
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_role TEXT := lower(btrim(COALESCE(p_meta_role, '')));
BEGIN
  IF v_role = '' THEN
    RETURN NULL;                       -- geen rol meegegeven → niets doen
  END IF;

  -- Onbekende waarde nooit doorlaten: die zou de CHECK op user_profiles.role
  -- breken en de hele registratie laten mislukken.
  IF v_role NOT IN ('superuser', 'supervisor', 'admin', 'pharmacy', 'courier') THEN
    RAISE WARNING '[rol-clamp] onbekende rol % gevraagd voor %; teruggevallen op courier.', v_role, p_email;
    RETURN 'courier';
  END IF;

  IF v_role = 'courier' THEN
    RETURN 'courier';                  -- zelfregistratie, altijd toegestaan
  END IF;

  -- Alles boven koerier vereist een openstaande uitnodiging op hetzelfde adres.
  -- Beide kanten genormaliseerd: de metadata kan in hoofdletters binnenkomen en
  -- een uitnodigingsrij evengoed.
  IF EXISTS (
    SELECT 1 FROM public.invitations i
    WHERE lower(btrim(i.email)) = lower(btrim(COALESCE(p_email, '')))
      AND lower(btrim(i.role))  = v_role
      AND i.accepted_at IS NULL
      AND i.expires_at > now()
  ) THEN
    RETURN v_role;
  END IF;

  RAISE WARNING '[rol-clamp] % gevraagd voor % zonder openstaande uitnodiging; teruggevallen op courier.', v_role, p_email;
  RETURN 'courier';
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_signup_role(TEXT, TEXT) FROM PUBLIC, anon, authenticated;


-- ────────────────────────────────────────────────────────────────────────
-- 2. handle_new_user — dezelfde trigger als migratie 002, maar met de clamp
--    en met pharmacy_ids uit de uitnodiging in plaats van uit de metadata.
--    SET search_path = public erbij: verplicht huiswerk bij SECURITY DEFINER
--    (zelfde reden als bij generate_schedule_shifts, planner-migratie 009).
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_role       TEXT;
  v_pharmacies TEXT[] := '{}';
BEGIN
  v_role := public.resolve_signup_role(new.email, new.raw_user_meta_data->>'role');

  -- Geen rol in de metadata → geen profiel, precies zoals voorheen.
  IF v_role IS NULL THEN
    RETURN new;
  END IF;

  IF v_role <> 'courier' THEN
    SELECT COALESCE(array_agg(DISTINCT i.pharmacy_id), '{}')
      INTO v_pharmacies
    FROM public.invitations i
    WHERE lower(btrim(i.email)) = lower(btrim(COALESCE(new.email, '')))
      AND lower(btrim(i.role))  = v_role
      AND i.accepted_at IS NULL
      AND i.expires_at > now()
      AND i.pharmacy_id IS NOT NULL;
  END IF;

  INSERT INTO public.user_profiles (id, name, role, pharmacy_ids)
  VALUES (
    new.id,
    COALESCE(new.raw_user_meta_data->>'name', new.email),
    v_role,
    v_pharmacies
  )
  ON CONFLICT (id) DO NOTHING;         -- idempotent bij herhaalde aanroep

  RETURN new;
END;
$$;

-- De trigger zelf blijft ongewijzigd; alleen defensief opnieuw zetten zodat
-- deze migratie ook op een database werkt waar hij ooit verdwenen is.
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie — verwacht: beide functies SECURITY DEFINER, trigger aanwezig,
-- en de clamp die 'superuser' zonder uitnodiging op 'courier' zet.
-- ────────────────────────────────────────────────────────────────────────
SELECT p.proname, p.prosecdef AS security_definer
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN ('resolve_signup_role', 'handle_new_user');

SELECT tgname FROM pg_trigger WHERE tgname = 'on_auth_user_created';

SELECT public.resolve_signup_role('niemand@example.com', 'superuser') AS moet_courier_zijn;

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
