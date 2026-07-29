-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed — RLS op invitations — migratie 014
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT).              │
-- │ Om te TESTEN zonder op te slaan: vervang de laatste regel COMMIT; door │
-- │ ROLLBACK;. Draai daarna supabase/tests/014_invitations_rls_test.sql    │
-- │ — dat bestand zet de policies zélf ook neer en rolt terug, dus je kunt │
-- │ het gedrag volledig beproeven vóór je hier COMMIT zet.                 │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAT ER MIS IS
-- Migratie 001 gaf invitations één policy: SELECT USING (true). Iedereen met de
-- anon-key kan dus alle uitnodigingen lezen, inclusief de kolom `token` — en met
-- een token neem je andermans uitnodiging over. Voor INSERT staat in de migraties
-- niets; live is er iets bijgekomen dat daar niet staat (drift), waardoor elke
-- ingelogde gebruiker een uitnodiging met een rol naar keuze kan wegschrijven.
-- Dat laatste is extra vervelend omdat migratie 015 de invitations-tabel als
-- betrouwbare bron gebruikt om de rol bij registratie te bepalen.
--
-- HET ECHTE SCHRIJFPAD (nagelopen in de bezorg-app-broncode)
--   * De rij wordt CLIENT-SIDE aangemaakt met de anon-key onder de sessie van de
--     uitnodiger: authService.ts:337 (`inviteUser`), gevolgd door
--     .select('token').single() om de token terug te lezen.
--   * De service-role-functies (send-invitation.ts / send-invite.ts) raken deze
--     tabel NIET aan; die roepen alleen auth.admin.inviteUserByEmail aan.
--   * Gevolg voor de policy: het leesrecht mag niet verdwijnen, anders faalt de
--     returning-select van inviteUser en gaat er geen mail uit.
--
-- VOORWAARDE OM VOORAF TE CONTROLEREN
-- De accept-flow leest de uitnodiging via de RPC get_invitation(p_token). Die
-- functie staat niet in de migraties (live aangemaakt). Is hij SECURITY DEFINER,
-- dan omzeilt hij RLS en raakt deze migratie hem niet. Het blok onderaan geeft
-- een WARNING als dat niet zo is.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────
-- 1. Bestaande SELECT- en INSERT-policies chirurgisch verwijderen.
--    Op naam droppen kan niet: de live namen zijn deels onbekend (drift, plus
--    handmatig teruggezette policies). Zelfde aanpak als migratie 002.
--    UPDATE/DELETE laten we met rust — daar bestaat geen policy voor, dus die
--    zijn al dicht.
-- ────────────────────────────────────────────────────────────────────────
DO $$
DECLARE pol record;
BEGIN
  FOR pol IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename  = 'invitations'
      AND cmd IN ('SELECT', 'INSERT', 'ALL')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.invitations', pol.policyname);
  END LOOP;
END $$;

ALTER TABLE public.invitations ENABLE ROW LEVEL SECURITY;

-- ────────────────────────────────────────────────────────────────────────
-- 2. Aanmaken: alleen bevoegden, en alleen op eigen naam.
--    De is_privileged()-eis houdt een koerier tegen die zichzelf via een
--    zelfgemaakte uitnodiging tot admin zou willen promoveren (zie 015).
--    De invited_by-eis houdt het spoor eerlijk: je zet geen uitnodiging op
--    naam van een collega.
-- ────────────────────────────────────────────────────────────────────────
CREATE POLICY "uitnodiging aanmaken" ON public.invitations
  FOR INSERT
  WITH CHECK (auth.uid() = invited_by AND public.is_privileged());

-- ────────────────────────────────────────────────────────────────────────
-- 3. Lezen: eigen uitnodigingen + alles voor bevoegden.
--    De eerste helft houdt de returning-select van inviteUser werkend, ook als
--    er ooit een niet-bevoegde rol mag uitnodigen. De publieke USING(true) is
--    daarmee weg: tokens zijn niet langer op te vragen met de anon-key.
-- ────────────────────────────────────────────────────────────────────────
CREATE POLICY "uitnodiging lezen" ON public.invitations
  FOR SELECT
  USING (auth.uid() = invited_by OR public.is_privileged());

-- ────────────────────────────────────────────────────────────────────────
-- 4. Waarschuwing als de accept-flow hier alsnog op leunt.
-- ────────────────────────────────────────────────────────────────────────
DO $$
DECLARE v_secdef BOOLEAN;
BEGIN
  SELECT p.prosecdef INTO v_secdef
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'get_invitation'
  LIMIT 1;

  IF v_secdef IS NULL THEN
    RAISE WARNING 'get_invitation() bestaat niet in deze database — de accept-flow leest de uitnodiging dan rechtstreeks en valt onder de nieuwe SELECT-policy.';
  ELSIF NOT v_secdef THEN
    RAISE WARNING 'get_invitation() is GEEN SECURITY DEFINER — die functie valt dus onder RLS en de accept-flow op token breekt met deze policies.';
  END IF;
END $$;

-- ────────────────────────────────────────────────────────────────────────
-- Verificatie — verwacht precies twee rijen: één INSERT met
-- (auth.uid() = invited_by AND is_privileged()) en één SELECT met
-- (auth.uid() = invited_by OR is_privileged()).
-- ────────────────────────────────────────────────────────────────────────
SELECT policyname, cmd, qual, with_check
FROM pg_policies
WHERE schemaname = 'public' AND tablename = 'invitations'
ORDER BY cmd, policyname;

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
