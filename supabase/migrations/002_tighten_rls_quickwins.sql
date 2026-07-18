-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed — RLS quick-wins — migratie 002
-- Twee laag-risico beveiligingsopschoningen op de GEDEELDE Greenspeed-database
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de bestaande Greenspeed-database.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT).              │
-- │ Om te TESTEN zonder op te slaan: vervang de laatste regel COMMIT; door │
-- │ ROLLBACK; en draai het geheel. De verificatie-SELECT onderaan toont    │
-- │ dan de eindstaat; ROLLBACK maakt daarna alles ongedaan.                │
-- │ Ben je tevreden? Zet COMMIT; terug en draai opnieuw.                    │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- Scope (bewust klein — grovere scoping van packages/pharmacies/institutions
-- volgt later als apart project mét smoke-tests, NIET hier):
--   1. pharmacy_codes — live had SELECT USING(true) ÉN DELETE USING(true):
--      iedereen met de anon-key kon koppelcodes lezen én verwijderen.
--   2. groups — live had SELECT USING(true): iedereen las groep/regionamen.
--
-- Vooraf geverifieerd in de app-broncode (bezorg-app), niets leunt hierop:
--   * pharmacy_codes: NUL client-side referenties (geen SELECT/INSERT/DELETE)
--     in Greenspeed-AIrouteplanner (app, services, netlify) én Greenspeed.
--     De tabel is legacy: de actuele koppelcode-flow draait op
--     pharmacies."courierCode" (authService.setPharmacyCourierCode →
--     .update() op pharmacies) + de SECURITY DEFINER-RPC link_courier_via_code
--     (migratie 012). SECURITY DEFINER omzeilt RLS → blijft werken.
--   * groups: enige client-read is supabaseService.fetchGroups(), aangeroepen
--     vanuit App.tsx:70 en PharmacyOverview.tsx:82 — beide met actieve sessie.
--     Writes gaan via de service_role netlify-functie groups-admin.ts (omzeilt
--     RLS). Scopen op auth.uid() IS NOT NULL is dus niet-brekend.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────
-- 1. pharmacy_codes — verwijder ALLEEN de publieke SELECT- en DELETE-policies.
--    De INSERT-policy (with_check auth.uid() = created_by) blijft behouden
--    zodat het aanmaken van codes blijft werken. Legitiem lezen loopt via
--    SECURITY DEFINER-RPC's die RLS omzeilen — die hebben geen SELECT-policy
--    nodig. We droppen chirurgisch op cmd, want de live policy-namen (o.a. de
--    DELETE-policy die niet in de migraties staat) zijn onbekend.
-- ────────────────────────────────────────────────────────────────────────
DO $$
DECLARE pol record;
BEGIN
  FOR pol IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename  = 'pharmacy_codes'
      AND cmd IN ('SELECT', 'DELETE')      -- INSERT/UPDATE blijven ongemoeid
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.pharmacy_codes', pol.policyname);
  END LOOP;
END $$;

-- RLS blijft aan (idempotent, defensief).
ALTER TABLE public.pharmacy_codes ENABLE ROW LEVEL SECURITY;

-- ────────────────────────────────────────────────────────────────────────
-- 2. groups — vervang de publieke SELECT door "alleen ingelogde gebruikers".
--    Voorkeur auth.uid() IS NOT NULL: fetchGroups() wordt door ingelogde
--    gebruikers van meerdere rollen aangeroepen; is_privileged() zou een
--    pharmacy-rol een lege groepen-dropdown geven. Strakkere scoping
--    (is_privileged()) kan later, als apart besluit.
--    Writes lopen via service_role (omzeilt RLS) → enkel een SELECT-policy nodig.
--    We droppen chirurgisch de bestaande SELECT-policy(s) en zetten de nieuwe.
-- ────────────────────────────────────────────────────────────────────────
DO $$
DECLARE pol record;
BEGIN
  FOR pol IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename  = 'groups'
      AND cmd IN ('SELECT', 'ALL')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.groups', pol.policyname);
  END LOOP;
END $$;

ALTER TABLE public.groups ENABLE ROW LEVEL SECURITY;

CREATE POLICY "groups_select_authenticated" ON public.groups
  FOR SELECT
  USING (auth.uid() IS NOT NULL);

-- ────────────────────────────────────────────────────────────────────────
-- Verificatie — toont de eindstaat binnen de transactie.
--   Verwacht:
--     pharmacy_codes → alleen nog een INSERT-rij (with_check auth.uid() = created_by);
--                      GEEN SELECT- of DELETE-rij meer.
--     groups         → precies één SELECT-rij met qual (auth.uid() IS NOT NULL).
-- ────────────────────────────────────────────────────────────────────────
SELECT tablename, policyname, cmd, qual, with_check
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('pharmacy_codes', 'groups')
ORDER BY tablename, cmd;

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
