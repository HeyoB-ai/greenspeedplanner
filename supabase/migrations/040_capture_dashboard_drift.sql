-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — drift uit het dashboard vastleggen — 040
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien.                      │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAAROM DEZE MIGRATIE BESTAANDE OBJECTEN OPNIEUW DEFINIEERT
--   Een vergelijking van pg_proc en pg_trigger met wat de migraties aanmaken
--   leverde zes functies op die live bestaan en in geen enkele migratie staan, en
--   drie triggers idem. Ze zijn via het Supabase-dashboard aangemaakt: kleine
--   letters, geen SET search_path, en niet de vorm die elke functie uit deze
--   pijplijn heeft. Wie de repo leest ziet ze dus niet, terwijl ze het gedrag wél
--   veranderen — een trigger grijpt in zonder dat iemand hem aanroept.
--
--   Deze migratie verandert daar niets aan behalve de vindbaarheid. Ze legt vast
--   wat er al is, zodat een nieuwe database hetzelfde gedrag krijgt en de volgende
--   lezer weet dat het bestaat. Het is dus normaal dat CREATE OR REPLACE hier een
--   object raakt dat er al staat: dat is de bedoeling, niet een vergissing.
--
-- WAT ER WEL EN NIET IN DEZE MIGRATIE ZIT
--   Drie van de zes wezen horen bij de bezorg-app en niet bij dit project:
--   get_invitation(), accept_invitation() en link_courier_via_code(). Die staan
--   al beschreven in migratie 002, 008 en 014 en horen in de migraties van díe
--   applicatie te worden vastgelegd, niet hier.
--
--   Drie wezen liggen wél bij dit project en staan hieronder, elk met de body
--   letterlijk zoals hij live is uitgelezen:
--
--     punt 1/2  shifts_no_past_insert()                   op public.shifts
--     punt 3    block_role_change()                       op public.user_profiles
--     punt 4    block_pharmacy_delete_with_packages()     op public.pharmacies
--
--   AAN DE FUNCTIES ZELF VERANDERT NIETS. De enige toevoeging is SET search_path
--   waar die ontbrak, en dat is bij alle drie zonder gevolg — geen van de bodies
--   raadpleegt een object dat via het zoekpad anders zou oplossen dan het al doet.
--   SECURITY DEFINER is bij elke functie overgenomen zoals hij live staat: bij
--   block_role_change() aan, bij de andere twee uit. Dat is geen slordigheid maar
--   het verschil tussen een controle die de rollen van ánderen moet kunnen lezen
--   en een controle die alleen naar de eigen rij kijkt.
--
--   DE TRIGGERS WORDEN NIET AANGERAAKT ALS ZE ER AL ZIJN. Zie de toelichting bij
--   punt 2; die geldt voor alle drie.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;


-- ────────────────────────────────────────────────────────────────────────
-- 1. shifts_no_past_insert — een dienst kan niet in het verleden beginnen.
--
--    Wat hij doet: bij een INSERT op public.shifts met een shift_date vóór
--    vandaag gooit hij een exception. Alleen op de DATUM, niet op de tijden, en
--    alleen bij INSERT. Een bestaande rij waarvan de datum intussen is verstreken
--    raakt hij dus niet aan — en dát is precies waarom declaration_sweep() werkt:
--    een afgelopen dienst bestaat nooit als INSERT, hij wordt vooruit ingepland en
--    wordt daarna vanzelf verleden tijd.
--
--    Waarom dit hier hoort: het heeft twee testbestanden gekost voordat iemand
--    hem tegenkwam (zie de kop van 036 en 037). Wie de migraties leest kon niet
--    weten dat public.shifts geen historische invoer accepteert.
--
--    DE BODY IS LETTERLIJK DIE VAN DE LIVE-FUNCTIE, met twee bewuste verschillen:
--      * SET search_path = public erbij. Zonder gevolg voor het gedrag — deze body
--        raadpleegt geen enkel object, alleen NEW.shift_date en current_date — maar
--        het is wel de vorm die de rest van deze migraties heeft.
--      * GEEN SECURITY DEFINER, net als live. Dat is geen vergeten regel: een
--        BEFORE-trigger die alleen een waarde controleert hoort in de rechten van
--        de schrijver te lopen. Definer maken zou een privilege toevoegen dat
--        niets oplost.
--    De melding is woord voor woord gelijk gehouden: hij staat in de logs van de
--    bezorg-app en in de foutmelding die een planner ziet.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.shifts_no_past_insert()
RETURNS trigger
LANGUAGE plpgsql SET search_path = public AS $fn$
BEGIN
  IF NEW.shift_date < current_date THEN
    RAISE EXCEPTION 'Een dienst kan niet op een datum in het verleden worden ingepland (%).',
                    NEW.shift_date;
  END IF;
  RETURN NEW;
END;
$fn$;

COMMENT ON FUNCTION public.shifts_no_past_insert() IS
  'Weigert een INSERT op shifts met een datum vóór vandaag. Alleen op INSERT en '
  'alleen op de datum; een bestaande rij die verstrijkt blijft ongemoeid. '
  'Bestond live al vóór migratie 040 en is daar alleen vastgelegd.';


-- ────────────────────────────────────────────────────────────────────────
-- 2. De trigger — alleen aanmaken als hij er nog niet is.
--
--    HIER GEEN DROP + CREATE, en dat wijkt af van de rest van deze migraties.
--    De reden: van deze trigger is de definitie (pg_get_triggerdef) niet
--    uitgelezen, alleen de naam en de functie. Zou hij live bijvoorbeeld
--    BEFORE INSERT OR UPDATE zijn in plaats van BEFORE INSERT, dan zou een
--    DROP + CREATE met de vorm hieronder hem stil versmallen — en dat is precies
--    het soort onzichtbare gedragswijziging waar deze migratie tegen bedoeld is.
--
--    Dus: bestaat hij, dan blijft hij staan en meldt de migratie zijn live-vorm,
--    zodat je die met de vorm hieronder kunt vergelijken. Bestaat hij niet — een
--    verse database — dan wordt hij aangemaakt en klopt het gedrag daar ook.
-- ────────────────────────────────────────────────────────────────────────
DO $do$
DECLARE v_def TEXT;
BEGIN
  SELECT pg_get_triggerdef(t.oid) INTO v_def
  FROM pg_trigger t
  WHERE t.tgrelid = 'public.shifts'::regclass
    AND t.tgname  = 'shifts_no_past_insert_trg'
    AND NOT t.tgisinternal;

  IF v_def IS NULL THEN
    CREATE TRIGGER shifts_no_past_insert_trg
      BEFORE INSERT ON public.shifts
      FOR EACH ROW EXECUTE FUNCTION public.shifts_no_past_insert();
    RAISE NOTICE 'Trigger shifts_no_past_insert_trg aangemaakt (bestond nog niet).';
  ELSE
    RAISE NOTICE 'Trigger bestaat al en is ONGEMOEID gelaten. Live-vorm: %', v_def;
    RAISE NOTICE 'Vergelijk met de vorm in punt 2 van deze migratie; wijken ze af, '
                 'neem dan de LIVE-vorm over in dit bestand.';
  END IF;
END
$do$;


-- ────────────────────────────────────────────────────────────────────────
-- 3. block_role_change — alleen een superuser mag een rol wijzigen.
--
--    Vuurt op een wijziging van user_profiles.role en gooit een exception tenzij
--    de aanroeper zelf superuser is. Body letterlijk zoals live, inclusief
--    SECURITY DEFINER: die is hier nodig en niet cosmetisch. De functie leest
--    user_profiles om de rol van de AANROEPER op te zoeken, en onder RLS ziet een
--    gewone gebruiker de rij van iemand anders niet — zonder definer zou de
--    controle dus altijd "geen superuser gevonden" opleveren en élke rolwijziging
--    weigeren, ook die van een superuser.
--
--    ⚠ auth.uid() IS NOT NULL IS EEN POORT, NIET EEN DETAIL.
--    Staat er geen sessie — de service-role key, of een aanroep vanuit een
--    databasefunctie — dan is auth.uid() NULL, is de hele voorwaarde onwaar en
--    gaat de wijziging ongehinderd door. Dat is naar alle waarschijnlijkheid
--    opzet: handle_new_user() (migratie 015) zet de eerste rol vanuit een trigger
--    op auth.users, en die loopt zonder sessie. Zonder deze uitzondering zou geen
--    enkele registratie kunnen slagen.
--
--    Wat het óók betekent, en wat je moet weten om deze database te begrijpen:
--    deze trigger beveiligt ALLEEN de weg via een ingelogde gebruiker. Elke
--    Edge Function in dit project draait met de service-role key en kan dus een
--    rol wijzigen zonder dat deze controle iets doet. Dat is geen gat om te
--    dichten — het is de reden dat de service-role key nooit in de browser komt.
--
--    Naast migratie 015: die klemt de rol bij het AANMAKEN van een account
--    (raw_user_meta_data uit de browser wordt genegeerd). Deze trigger klemt hem
--    daarna. Twee helften van dezelfde afspraak, waarvan er tot nu toe één in de
--    migraties stond.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.block_role_change()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF NEW.role IS DISTINCT FROM OLD.role
     AND auth.uid() IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM public.user_profiles
       WHERE id = auth.uid() AND role = 'superuser'
     )
  THEN
    RAISE EXCEPTION 'Rol mag alleen door een superuser gewijzigd worden';
  END IF;
  RETURN NEW;
END;
$fn$;

COMMENT ON FUNCTION public.block_role_change() IS
  'Weigert een wijziging van user_profiles.role tenzij de aanroeper superuser is. '
  'Slaat de controle over als auth.uid() NULL is (service-role of een '
  'databasefunctie) — dat is nodig omdat handle_new_user() de eerste rol zonder '
  'sessie zet. Bestond live al vóór migratie 040 en is daar alleen vastgelegd.';

DO $do$
DECLARE v_def TEXT;
BEGIN
  SELECT pg_get_triggerdef(t.oid) INTO v_def
  FROM pg_trigger t
  WHERE t.tgrelid = 'public.user_profiles'::regclass
    AND t.tgname  = 'trg_block_role_change'
    AND NOT t.tgisinternal;

  IF v_def IS NULL THEN
    -- BEFORE UPDATE en niet UPDATE OF role: de body controleert zelf of de rol
    -- werkelijk wijzigt (IS DISTINCT FROM), dus een breder bereik verandert het
    -- gedrag niet en kan geen kolom missen.
    CREATE TRIGGER trg_block_role_change
      BEFORE UPDATE ON public.user_profiles
      FOR EACH ROW EXECUTE FUNCTION public.block_role_change();
    RAISE NOTICE 'Trigger trg_block_role_change aangemaakt (bestond nog niet).';
  ELSE
    RAISE NOTICE 'trg_block_role_change bestaat al en is ONGEMOEID gelaten. Live: %', v_def;
  END IF;
END
$do$;


-- ────────────────────────────────────────────────────────────────────────
-- 4. block_pharmacy_delete_with_packages — een apotheek met pakketten blijft.
--
--    Vuurt bij het verwijderen van een apotheek en weigert dat zolang er nog
--    pakketten aan hangen, met het aantal en de naam in de melding. Body letterlijk
--    zoals live, inclusief het ONTBREKEN van SECURITY DEFINER — bewust niet
--    toegevoegd, want wie een apotheek mag verwijderen mag ook zien wat eraan
--    hangt, en definer zou hier een privilege toevoegen dat niets oplost.
--
--    ⚠ DEZE TRIGGER LEEST EEN TABEL VAN EEN ANDERE APPLICATIE.
--    public.packages met "pharmacyId" in camelCase is een tabel van de ROUTE
--    PLANNER, niet van de Planner; beide apps delen dezelfde database. Deze
--    migratie legt daarmee een afhankelijkheid vast op een object dat ELDERS wordt
--    beheerd en niet in deze repo staat. Gevolgen om te kennen:
--
--      * Verdwijnt public.packages, of wordt "pharmacyId" daar hernoemd, dan
--        breekt het verwijderen van een apotheek in DEZE applicatie — met een
--        foutmelding over een tabel die hier nergens voorkomt.
--      * De camelCase is geen vergissing maar de schrijfwijze van die andere app.
--        De dubbele aanhalingstekens zijn dus verplicht; zonder die tekens zoekt
--        Postgres naar een kolom "pharmacyid" en bestaat hij niet.
--      * Draai je deze migratie op een database ZONDER de route planner, dan
--        bestaat public.packages niet. De functie compileert dan wel — plpgsql
--        lost tabelnamen pas op bij uitvoering — maar de eerste poging om een
--        apotheek te verwijderen faalt met "relation public.packages does not
--        exist". De FUNCTIE wordt dan wel vastgelegd maar de TRIGGER niet; zie het
--        DO-blok onderaan dit punt.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.block_pharmacy_delete_with_packages()
RETURNS trigger
LANGUAGE plpgsql SET search_path = public AS $fn$
DECLARE
  n INT;
BEGIN
  SELECT count(*) INTO n FROM public.packages WHERE "pharmacyId" = OLD.id;
  IF n > 0 THEN
    RAISE EXCEPTION
      'Apotheek "%" heeft nog % pakket(ten) gekoppeld; verplaats die eerst naar een andere apotheek voordat je verwijdert.',
      OLD.name, n;
  END IF;
  RETURN OLD;
END;
$fn$;

COMMENT ON FUNCTION public.block_pharmacy_delete_with_packages() IS
  'Weigert het verwijderen van een apotheek zolang public.packages er nog naar '
  'verwijst. LET OP: packages is een tabel van de route planner, niet van deze '
  'applicatie. Bestond live al vóór migratie 040 en is daar alleen vastgelegd.';

-- De functie mag altijd bestaan: plpgsql lost tabelnamen pas bij UITVOERING op,
-- dus zonder public.packages is dit gewoon een functie die niemand aanroept. De
-- TRIGGER is het gevaarlijke deel — die zou het verwijderen van een apotheek
-- laten falen op een tabel die er niet is. Vandaar de poort hieronder.
DO $do$
BEGIN
  IF to_regclass('public.packages') IS NULL THEN
    RAISE NOTICE 'public.packages bestaat niet in deze database (route planner niet '
                 'aanwezig). Trigger trg_block_pharmacy_delete NIET aangemaakt — anders '
                 'zou het verwijderen van een apotheek voortaan falen op een ontbrekende '
                 'tabel. De functie staat er wel en doet niets zolang niets hem aanroept.';
  ELSIF EXISTS (
    SELECT 1 FROM pg_trigger t
    WHERE t.tgrelid = 'public.pharmacies'::regclass
      AND t.tgname  = 'trg_block_pharmacy_delete'
      AND NOT t.tgisinternal
  ) THEN
    RAISE NOTICE 'trg_block_pharmacy_delete bestaat al en is ONGEMOEID gelaten.';
  ELSE
    CREATE TRIGGER trg_block_pharmacy_delete
      BEFORE DELETE ON public.pharmacies
      FOR EACH ROW EXECUTE FUNCTION public.block_pharmacy_delete_with_packages();
    RAISE NOTICE 'Trigger trg_block_pharmacy_delete aangemaakt (bestond nog niet).';
  END IF;
END
$do$;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie
--   1. De drie functies, met hun definer-stand en instellingen. Verwacht:
--      block_role_change met security_definer = true, de andere twee false, en
--      bij alle drie search_path=public in de instellingen.
--   2. Alle niet-interne triggers op de drie tabellen. Verwacht zes op shifts, en
--      één op user_profiles en pharmacies. Wijkt een LIVE-vorm af van wat hierboven
--      staat, neem dan de live-vorm over in dit bestand — de migratie heeft ze
--      bewust niet aangeraakt.
--   3. Wat er ná deze migratie nog verweesd is. Verwacht: precies de drie van de
--      bezorg-app, en niets anders.
-- ────────────────────────────────────────────────────────────────────────
SELECT p.proname,
       p.prosecdef AS security_definer,
       p.proconfig AS instellingen
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('shifts_no_past_insert', 'block_role_change',
                    'block_pharmacy_delete_with_packages')
ORDER BY p.proname;

SELECT c.relname AS tabel, t.tgname, pg_get_triggerdef(t.oid) AS definitie
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
WHERE t.tgrelid IN ('public.shifts'::regclass,
                    'public.user_profiles'::regclass,
                    'public.pharmacies'::regclass)
  AND NOT t.tgisinternal
ORDER BY c.relname, t.tgname;

SELECT p.proname
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('get_invitation', 'accept_invitation', 'link_courier_via_code')
ORDER BY p.proname;

COMMIT;   -- vervang door ROLLBACK; voor een dry-run zonder op te slaan
