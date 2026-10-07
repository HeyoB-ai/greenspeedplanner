-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — het woonadres van een medewerker wordt bewaard — 057
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Daarna supabase/tests/057_employee_addresses_test.sql.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien.                       │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- ONTWERPWIJZIGING, 7 OKTOBER 2026
--   Tot nu toe ging een woonadres één keer naar de Edge Function
--   courier-distances en werd het nergens bewaard. Dat was een bewuste keuze:
--   geen bewaartermijn, en een lek levert niemands woonplaats op.
--
--   De prijs bleek te hoog. Elke herberekening vroeg het adres opnieuw — en die
--   herberekening is nodig zodra een koerier aan een nieuwe apotheek wordt
--   gekoppeld, want zonder afstand naar die apotheek blijft zijn declaratie daar
--   onvolledig. In de praktijk betekende dat: het adres opzoeken, overtypen, en
--   bij een tikfout een verkeerde vergoeding. Vanaf nu wordt het adres één keer
--   ingevoerd (ook in bulk, via SQL) en daarna hergebruikt.
--
-- WAT DIT VRAAGT VAN DE AFSCHERMING
--   Een bewaard woonadres is een ander soort gegeven dan een afstand. Daarom:
--     * een eigen tabel, niet een kolom op employees — employees wordt door
--       meer schermen gelezen, en een kolom erbij zou overal meelopen;
--     * alleen planners, via is_privileged(). Koeriers krijgen geen enkele
--       toegang, ook niet tot hun eigen adres: er is geen scherm dat het nodig
--       heeft, en elke ingang is een ingang meer;
--     * NIET in het logboek (migratie 056). Dat is append-only; een adres dat
--       daarin terechtkomt is niet meer te wissen, ook niet als iemand uit
--       dienst gaat of om verwijdering vraagt. Het logboek moet kunnen bewijzen
--       wát er veranderde — bij een adres is "het adres van X is gewijzigd" al
--       te veel als het oude adres er voor altijd naast staat.
--
-- ÉÉN VRIJE REGEL
--   "Zwarteweg 31, 1405 AB Bussum" en geen losse kolommen voor straat, postcode
--   en plaats. Het adres heeft hier één doel: de geocoder voeden, en die leest
--   een vrije regel net zo goed. Losse kolommen zouden validatie suggereren die
--   er niet is, en de bulkinvoer via SQL lastiger maken.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────
-- 1. De tabel.
--
--    Op employees en niet op user_profiles: het adres hoort bij de persoon in
--    de personeelsadministratie, niet bij een inlogaccount. ON DELETE CASCADE,
--    zodat een verwijderde medewerker geen adres achterlaat.
--
--    updated_by ON DELETE SET NULL: als het profiel van de planner verdwijnt,
--    blijft het adres staan. Wie het invoerde is dan niet meer bekend, maar het
--    adres zelf is niet minder juist geworden.
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.employee_addresses (
  employee_id  UUID PRIMARY KEY REFERENCES public.employees(id) ON DELETE CASCADE,
  address_line TEXT NOT NULL
               CONSTRAINT employee_addresses_line_chk CHECK (length(btrim(address_line)) >= 6),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by   UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL
);

COMMENT ON TABLE public.employee_addresses IS
  'Woonadres per medewerker, één vrije regel. Alleen voor planners; bewust niet in audit_log (056). Sinds 7-10-2026.';

-- ────────────────────────────────────────────────────────────────────────
-- 2. Afscherming.
--
--    Precies één policy, zoals bij courier_contacts (migratie 011): alles voor
--    is_privileged(), niets voor de rest.
--
--    Maar er komt GEEN tabelrecht voor authenticated bij. Het scherm leest en
--    schrijft uitsluitend via courier_address_get/_set hieronder; met een
--    tabelrecht erbij zou elke planner-sessie de hele tabel in één verzoek via
--    PostgREST kunnen ophalen. De policy is de tweede verdedigingslinie, voor
--    het geval iemand dat recht later toch toekent.
--
--    service_role krijgt SELECT, want de Edge Function courier-distances leest
--    het adres zelf als er geen wordt meegestuurd. Ook SELECT op employees: die
--    functie zoekt via employees.user_profile_id van koerier naar medewerker, en
--    zonder expliciet recht loopt hij op "permission denied" — nieuwe objecten
--    krijgen hier geen automatische rechten (zie de toelichting in 018, punt 10).
--    Alleen lezen: opslaan loopt uitsluitend via courier_address_set.
-- ────────────────────────────────────────────────────────────────────────
ALTER TABLE public.employee_addresses ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "addresses_privileged" ON public.employee_addresses;
CREATE POLICY "addresses_privileged" ON public.employee_addresses
  FOR ALL USING (public.is_privileged()) WITH CHECK (public.is_privileged());

REVOKE ALL ON public.employee_addresses FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.employee_addresses TO service_role;
GRANT SELECT ON public.employees          TO service_role;

-- Uitdrukkelijk geen audit-trigger. Migratie 056 zet zijn triggers met een vaste
-- lijst en deze tabel staat daar niet in, maar een DROP hier maakt het
-- onafhankelijk van wat er ooit aan die lijst verandert: draait iemand 056
-- opnieuw met een bredere lijst, dan haalt het opnieuw draaien van 057 hem weer
-- weg. Zie de kop voor het waarom.
DROP TRIGGER IF EXISTS audit_employee_addresses ON public.employee_addresses;


-- ────────────────────────────────────────────────────────────────────────
-- 3. courier_address_get — het bewaarde adres van een koerier.
--
--    Op koerier-id en niet op medewerker-id, omdat het scherm Afstanden in
--    koeriers denkt: courier_home_overview() geeft user_profiles-id's terug.
--    De vertaling naar de medewerker gebeurt hier, via employees.user_profile_id.
--
--    NULL betekent: medewerker gevonden, nog geen adres. Een koerier zonder
--    medewerkerregel is iets anders — dan valt er niets te bewaren en zegt de
--    foutmelding waar het op te lossen is.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.courier_address_get(p_courier_id UUID)
RETURNS TEXT
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_employee UUID;
  v_address  TEXT;
BEGIN
  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'Alleen planners mogen woonadressen inzien.' USING ERRCODE = '42501';
  END IF;

  SELECT e.id INTO v_employee FROM public.employees e WHERE e.user_profile_id = p_courier_id;
  IF v_employee IS NULL THEN
    RAISE EXCEPTION 'Deze koerier heeft geen medewerkerregel, dus er kan geen adres bij. '
                    'Koppel hem eerst onder Beheer → Medewerkers.';
  END IF;

  SELECT a.address_line INTO v_address
  FROM public.employee_addresses a WHERE a.employee_id = v_employee;

  RETURN v_address;
END;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 4. courier_address_set — opslaan, of met een lege regel verwijderen.
--
--    Leeg is verwijderen en niet "laat staan". Anders is er geen weg om een
--    adres kwijt te raken behalve een DELETE in de SQL Editor, en juist bij een
--    woonadres moet wissen even makkelijk zijn als invullen.
--
--    De lengtecontrole staat hier óók, en niet alleen in de CHECK: die laatste
--    geeft "violates check constraint", en daar heeft een planner niets aan.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.courier_address_set(p_courier_id UUID, p_address TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_employee UUID;
  v_address  TEXT := NULLIF(btrim(COALESCE(p_address, '')), '');
BEGIN
  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'Alleen planners mogen woonadressen wijzigen.' USING ERRCODE = '42501';
  END IF;

  SELECT e.id INTO v_employee FROM public.employees e WHERE e.user_profile_id = p_courier_id;
  IF v_employee IS NULL THEN
    RAISE EXCEPTION 'Deze koerier heeft geen medewerkerregel, dus er kan geen adres bij. '
                    'Koppel hem eerst onder Beheer → Medewerkers.';
  END IF;

  IF v_address IS NULL THEN
    DELETE FROM public.employee_addresses WHERE employee_id = v_employee;
    RETURN;
  END IF;

  IF length(v_address) < 6 THEN
    RAISE EXCEPTION 'Vul een volledig adres in: straat, huisnummer, postcode en plaats.';
  END IF;

  INSERT INTO public.employee_addresses (employee_id, address_line, updated_at, updated_by)
  VALUES (v_employee, v_address, now(), auth.uid())
  ON CONFLICT (employee_id) DO UPDATE
    SET address_line = EXCLUDED.address_line,
        updated_at   = now(),
        updated_by   = auth.uid();
END;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 5. courier_home_overview — met has_address.
--
--    De definitie uit migratie 018, met één kolom erbij. Een gewijzigd
--    resultaattype kan niet met CREATE OR REPLACE, dus DROP en CREATE — en dan
--    is de functie zijn rechten kwijt. Op 6 oktober verloor declaration_overview
--    zo zijn EXECUTE voor authenticated en stond het scherm Declaraties leeg.
--    De REVOKE/GRANT staat daarom direct hieronder en niet pas onderaan, en de
--    verificatie én het testbestand controleren hem expliciet.
--
--    Alleen óf er een adres is, nooit het adres zelf: dit overzicht wordt bij
--    elk openen van het scherm geladen, voor alle koeriers tegelijk.
-- ────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.courier_home_overview();

CREATE FUNCTION public.courier_home_overview()
RETURNS TABLE (
  courier_id       UUID,
  courier_name     TEXT,
  home_pharmacy_id TEXT,
  distances        INT,
  computed_at      TIMESTAMPTZ,
  has_address      BOOLEAN
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT up.id, up.name, up.home_pharmacy_id,
         (SELECT count(*)::INT       FROM public.courier_distances cd WHERE cd.courier_id = up.id),
         (SELECT max(cd.computed_at) FROM public.courier_distances cd WHERE cd.courier_id = up.id),
         EXISTS (SELECT 1
                 FROM public.employees e
                 JOIN public.employee_addresses a ON a.employee_id = e.id
                 WHERE e.user_profile_id = up.id)
  FROM public.user_profiles up
  WHERE up.role = 'courier'
    AND public.is_privileged()
  ORDER BY up.name;
$$;

REVOKE ALL     ON FUNCTION public.courier_home_overview() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.courier_home_overview() TO authenticated, service_role;


-- ────────────────────────────────────────────────────────────────────────
-- 6. Rechten op de twee adresfuncties.
--    Alleen authenticated; de controle op planner zit in de functie zelf. Niet
--    voor service_role: die heeft geen auth.uid() en zou altijd geweigerd
--    worden — de Edge Function leest de tabel rechtstreeks (zie punt 2).
-- ────────────────────────────────────────────────────────────────────────
REVOKE ALL     ON FUNCTION public.courier_address_get(UUID)       FROM PUBLIC, anon;
REVOKE ALL     ON FUNCTION public.courier_address_set(UUID, TEXT) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.courier_address_get(UUID)       TO authenticated;
GRANT  EXECUTE ON FUNCTION public.courier_address_set(UUID, TEXT) TO authenticated;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie
-- ────────────────────────────────────────────────────────────────────────

-- Verwacht: true, true, false. De les van 6 oktober: na een DROP FUNCTION moet
-- authenticated de functie nog kunnen uitvoeren, en anon nog steeds niet.
SELECT has_function_privilege('authenticated', 'public.courier_home_overview()', 'EXECUTE') AS authenticated_mag,
       has_function_privilege('service_role',  'public.courier_home_overview()', 'EXECUTE') AS service_role_mag,
       has_function_privilege('anon',          'public.courier_home_overview()', 'EXECUTE') AS anon_mag;

-- Verwacht: has_address staat in het resultaat.
SELECT pg_get_function_result('public.courier_home_overview()'::REGPROCEDURE) LIKE '%has_address boolean%'
       AS heeft_has_address;

-- Verwacht: true, één policy, en false, false, true.
SELECT c.relrowsecurity AS rls_aan,
       (SELECT count(*) FROM pg_policy p WHERE p.polrelid = c.oid) AS policies,
       has_table_privilege('anon',          'public.employee_addresses', 'SELECT') AS anon_leest,
       has_table_privilege('authenticated', 'public.employee_addresses', 'SELECT') AS authenticated_leest,
       has_table_privilege('service_role',  'public.employee_addresses', 'SELECT') AS service_role_leest
FROM pg_class c WHERE c.oid = 'public.employee_addresses'::REGCLASS;

-- Verwacht: 0. Geen audit-trigger op de adressen.
SELECT count(*) AS audit_triggers
FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
WHERE t.tgrelid = 'public.employee_addresses'::REGCLASS AND p.proname = 'audit_capture';

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
