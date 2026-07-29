-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed — registratie levert altijd een koerier op — migratie 015
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
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
-- Registratie levert voortaan altijd een koerier op, wat de metadata ook zegt.
-- Geen uitzonderingspad en geen opzoeking in invitations: alle accounts boven
-- koerier worden met de hand aangemaakt (zie hieronder), dus de database hoeft
-- geen enkele verhoging meer te kunnen produceren. Stond er iets anders dan
-- 'courier' in de metadata, dan komt dat als WARNING in de Postgres-logs — zo
-- zie je terug dát iemand het probeerde.
--
-- Ook pharmacy_ids komt niet meer uit de metadata: die array stuurt toegang aan
-- (utils/pharmacyAccess.ts in de bezorg-app) en was net zo goed door de client
-- te vullen. Een zelfgeregistreerde koerier begint dus zonder apotheken en komt
-- binnen via de koppelcode, zoals bedoeld.
--
-- ┌─ HOE JE EEN ACCOUNT BOVEN KOERIER AANMAAKT ────────────────────────────┐
-- │ Dit geldt voor superuser, supervisor, admin ÉN pharmacy — alles wat     │
-- │ geen koerier is.                                                         │
-- │                                                                          │
-- │ De trigger vuurt bij ELKE nieuwe rij in auth.users, ook bij eentje die   │
-- │ jij in het dashboard aanmaakt: de database kan niet zien of een rij van  │
-- │ het publieke formulier komt of van jouw hand. Wat wél verschilt is de    │
-- │ metadata, en daar zit het pad:                                           │
-- │                                                                          │
-- │   1. Dashboard → Authentication → Add user. E-mail + wachtwoord,         │
-- │      "Auto Confirm User" aan, en laat de user-metadata LEEG (geen        │
-- │      role-veld). Zonder rol in de metadata maakt de trigger géén         │
-- │      profielrij aan — precies wat je wilt.                               │
-- │   2. SQL Editor, met de juiste rol:                                      │
-- │                                                                          │
-- │        INSERT INTO public.user_profiles (id, name, role, pharmacy_ids)   │
-- │        SELECT id, 'Naam van de persoon', 'pharmacy', ARRAY['ph-123']     │
-- │        FROM auth.users WHERE email = 'iemand@apotheek.nl';               │
-- │                                                                          │
-- │      Rollen: 'superuser' | 'supervisor' | 'admin' | 'pharmacy'.          │
-- │      pharmacy_ids alleen vullen bij 'pharmacy' en 'admin'.               │
-- │                                                                          │
-- │ Zet je per ongeluk tóch role in de metadata, dan krijg je een koerier    │
-- │ (met een WARNING in de logs). Rechtzetten:                               │
-- │        UPDATE public.user_profiles SET role = 'pharmacy'                 │
-- │        WHERE id = '<uuid>';                                              │
-- │ Dat mag: in de SQL Editor draai je als postgres, en de kolomrechten uit  │
-- │ blok A gelden voor de rol `authenticated`, niet voor jou.                │
-- └──────────────────────────────────────────────────────────────────────────┘
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- Uit een eerdere opzet van deze migratie; de uitnodigingsflow wordt niet
-- gebruikt, dus deze helper heeft geen taak meer.
DROP FUNCTION IF EXISTS public.resolve_signup_role(TEXT, TEXT);


-- ────────────────────────────────────────────────────────────────────────
-- handle_new_user — dezelfde trigger als migratie 002, maar zonder enig pad
-- naar een rol boven koerier.
-- SET search_path = public erbij: verplicht huiswerk bij SECURITY DEFINER
-- (zelfde reden als bij generate_schedule_shifts, planner-migratie 009).
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_meta_role TEXT := lower(btrim(COALESCE(new.raw_user_meta_data->>'role', '')));
BEGIN
  -- Geen rol in de metadata → geen profiel. Ongewijzigd gedrag t.o.v. migratie
  -- 002, en tegelijk het pad voor handmatig aangemaakte accounts: die krijgen
  -- hun profielrij met de hand, mét de juiste rol.
  IF v_meta_role = '' THEN
    RETURN new;
  END IF;

  -- Alles wat geen koerier is, is een poging tot verhoging of een bug in de
  -- app. Beide wil je terugzien; geen van beide mag doorgaan.
  IF v_meta_role <> 'courier' THEN
    RAISE WARNING '[rol-clamp] registratie voor % vroeg rol %; aangemaakt als courier.',
                  new.email, v_meta_role;
  END IF;

  INSERT INTO public.user_profiles (id, name, role, pharmacy_ids)
  VALUES (
    new.id,
    COALESCE(new.raw_user_meta_data->>'name', new.email),
    'courier',                          -- de enige rol die hier kan ontstaan
    '{}'::TEXT[]                        -- apotheken komen via de koppelcode
  )
  ON CONFLICT (id) DO NOTHING;          -- idempotent bij herhaalde aanroep

  RETURN new;
END;
$$;

-- De trigger zelf blijft ongewijzigd; alleen defensief opnieuw gezet zodat deze
-- migratie ook werkt op een database waar hij ooit verdwenen is.
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie — verwacht: handle_new_user aanwezig en SECURITY DEFINER,
-- trigger aanwezig, en resolve_signup_role weg.
-- ────────────────────────────────────────────────────────────────────────
SELECT p.proname, p.prosecdef AS security_definer
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN ('handle_new_user', 'resolve_signup_role');

SELECT tgname FROM pg_trigger WHERE tgname = 'on_auth_user_created';

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
