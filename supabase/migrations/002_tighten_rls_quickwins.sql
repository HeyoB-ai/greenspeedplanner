-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed — RLS quick-wins — migratie 002
-- Twee laag-risico beveiligingsopschoningen op de GEDEELDE Greenspeed-database
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de bestaande Greenspeed-database.
--
-- Scope (bewust klein — de grovere scoping van packages/pharmacies/institutions
-- volgt later als apart project mét smoke-tests, NIET hier):
--   1. pharmacy_codes — live had SELECT USING(true) ÉN DELETE USING(true):
--      iedereen met de anon-key kon koppelcodes lezen én verwijderen.
--   2. groups — live had SELECT USING(true): iedereen las groep/regionamen.
--
-- Vooraf geverifieerd in de app-broncode (bezorg-app), niets leunt hierop:
--   * pharmacy_codes: NUL client-side referenties. De code-validatie loopt
--     server-side via link_courier_via_code()/courier_code_lookup (migraties
--     011/012), beide SECURITY DEFINER → die omzeilen RLS en blijven werken.
--     Ook code-generatie gebeurt server-side (geen client .from-insert).
--   * groups: enige client-read is supabaseService.fetchGroups(), aangeroepen
--     vanuit App.tsx:70 en PharmacyOverview.tsx:82 — beide met actieve sessie.
--     Writes gaan via de service_role netlify-functie groups-admin.ts (omzeilt
--     RLS). Scopen op auth.uid() IS NOT NULL is dus niet-brekend.
-- ════════════════════════════════════════════════════════════════════════


-- ────────────────────────────────────────────────────────────────────────
-- 1. pharmacy_codes — volledig dichttrekken voor clients.
--    Eindstaat: RLS aan, GÉÉN permissive policies. Legitieme toegang loopt
--    uitsluitend via SECURITY DEFINER-functies (die RLS omzeilen).
--    We droppen dynamisch ALLE bestaande policies, want de live policy-namen
--    (o.a. de DELETE-policy die niet in de migraties staat) zijn onbekend.
-- ────────────────────────────────────────────────────────────────────────
DO $$
DECLARE pol record;
BEGIN
  FOR pol IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'pharmacy_codes'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.pharmacy_codes', pol.policyname);
  END LOOP;
END $$;

-- RLS blijft aan (idempotent, defensief) → zonder policy = deny-all voor clients.
ALTER TABLE public.pharmacy_codes ENABLE ROW LEVEL SECURITY;


-- ────────────────────────────────────────────────────────────────────────
-- 2. groups — publieke SELECT vervangen door "alleen ingelogde gebruikers".
--    Writes lopen via service_role (omzeilt RLS), dus enkel een SELECT-policy
--    nodig. We droppen eerst alle bestaande policies (naam-drift live vs.
--    migratie 009) en zetten daarna de enige benodigde policy neer.
-- ────────────────────────────────────────────────────────────────────────
DO $$
DECLARE pol record;
BEGIN
  FOR pol IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'groups'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.groups', pol.policyname);
  END LOOP;
END $$;

ALTER TABLE public.groups ENABLE ROW LEVEL SECURITY;

CREATE POLICY "groups_select_authenticated" ON public.groups
  FOR SELECT
  USING (auth.uid() IS NOT NULL);


-- ════════════════════════════════════════════════════════════════════════
-- Verificatie na uitvoeren (moet de nieuwe eindstaat tonen):
--   SELECT tablename, policyname, cmd, qual
--   FROM pg_policies
--   WHERE schemaname='public' AND tablename IN ('pharmacy_codes','groups')
--   ORDER BY tablename, cmd;
--   -- verwacht: pharmacy_codes = 0 rijen; groups = 1 rij (SELECT, auth.uid() IS NOT NULL)
-- ════════════════════════════════════════════════════════════════════════
