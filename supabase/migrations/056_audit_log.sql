-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — logboek: wie heeft wat wanneer gewijzigd — 056
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien.                       │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- AANLEIDING
--   Op 3 oktober zijn elf diensten buiten de Planner om via SQL bevestigd. Dat
--   was achteraf niet te herleiden: de rijen stonden op 'planned' en verder was
--   er niets. Geen wie, geen wanneer, geen vorige waarde.
--
--   Het gaat hier niet om wantrouwen maar om naspeurbaarheid. Een dienst die
--   van status verandert heeft gevolgen voor een koerier (hij krijgt mail), voor
--   een apotheek (het komt op de factuur) en voor de meerwerkketen. Kan niemand
--   terugzien wie dat deed, dan is de enige manier om een fout te herstellen:
--   raden.
--
-- WAAROM EEN TRIGGER EN NIET LOGGEN IN DE APP
--   Juist de wijziging die aanleiding was ging NIET door de app. Een logboek dat
--   in plannerService.ts wordt bijgehouden mist precies het geval waarvoor het
--   bedoeld is. Een trigger zit onder alles: de Planner, de bezorg-app, de Edge
--   Functions, de cron, en iemand met de SQL Editor open.
--
-- HET LOGBOEK MAG NOOIT IETS TEGENHOUDEN
--   Het hele lichaam van audit_capture() staat in een EXCEPTION-blok. Gaat er
--   iets mis — een cast die faalt, een catalogusquery die niets vindt — dan
--   volgt er een WARNING en gaat de oorspronkelijke wijziging gewoon door. Een
--   planner die een dienst niet kan opslaan omdat het logboek stuk is, is erger
--   dan een ontbrekende logregel. Dat kost een subtransactie per rij; bij deze
--   tabelgroottes is dat de prijs waard.
--
-- GEDEELDE DATABASE
--   Deze migratie voegt alleen toe: één tabel, vijf functies, triggers. Geen
--   bestaande kolom, constraint of functie wordt aangeraakt — ook is_privileged()
--   niet. De bezorg-app en AIrouteplanner merken er niets van behalve dat hún
--   schrijfacties óók in het logboek komen. Dat is de bedoeling: 'source' en
--   'actor_role' laten zien waar een wijziging vandaan kwam.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────
-- 1. De tabel.
--
--    actor_name en actor_role zijn KOPIEËN van het moment van loggen. Een join
--    op user_profiles zou netter lijken, maar een logregel uit 2026 moet in 2028
--    nog leesbaar zijn, ook als dat profiel dan verwijderd of van rol veranderd
--    is. Dat is dezelfde afweging als bij courier_note in extra_work (031).
--
--    GEEN foreign keys, met opzet. actor_id, shift_id en courier_id zijn kale
--    uuid-kolommen. Een FK met ON DELETE SET NULL of CASCADE zou bij het
--    verwijderen van een profiel of dienst een UPDATE of DELETE op deze tabel
--    doen — en dan op de append-only-wacht hieronder stuklopen, waardoor het
--    verwijderen van die dienst zelf mislukt. Een logregel over een verwijderde
--    dienst moet juist blíjven bestaan.
--
--    txid groepeert regels uit één transactie. Eén druk op "Opslaan" in het
--    dienstformulier raakt shifts én shift_pharmacies; één klik op "bevestig
--    alles" raakt tien diensten. Zonder dat nummer zijn dat losse gebeurtenissen
--    die toevallig op dezelfde seconde staan.
--
--    shift_id en courier_id staan als eigen kolom naast de JSON. Een scherm dat
--    "alles rond deze dienst" moet tonen zou anders door jsonb moeten zoeken, en
--    dat is niet te indexeren zonder voor elke tabel te weten waar de sleutel
--    zit.
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.audit_log (
  id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  occurred_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  txid           BIGINT      NOT NULL,

  actor_id       UUID,
  actor_name     TEXT,
  actor_role     TEXT,
  source         TEXT        NOT NULL,
  app_name       TEXT,

  table_name     TEXT        NOT NULL,
  action         TEXT        NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
  row_id         TEXT,

  shift_id       UUID,
  courier_id     UUID,

  old_data       JSONB,
  new_data       JSONB,
  changed_fields TEXT[]
);

-- Voor het geval een eerdere proefversie van deze migratie al gedraaid heeft
-- zonder deze twee kolommen.
ALTER TABLE public.audit_log ADD COLUMN IF NOT EXISTS actor_role TEXT;
ALTER TABLE public.audit_log ADD COLUMN IF NOT EXISTS app_name   TEXT;

ALTER TABLE public.audit_log DROP CONSTRAINT IF EXISTS audit_log_source_chk;
ALTER TABLE public.audit_log ADD CONSTRAINT audit_log_source_chk
  CHECK (source IN ('app', 'formulier', 'service', 'cron', 'sql', 'onbekend'));

COMMENT ON TABLE public.audit_log IS
  'Append-only logboek van wijzigingen op planningsdata. Gevuld door audit_capture(), te lezen via audit_log_list().';
COMMENT ON COLUMN public.audit_log.source IS
  '''app'' ingelogd, ''formulier'' token-pagina, ''service'' Edge Function, ''cron'' pg_cron, ''sql'' directe toegang, ''onbekend''.';
COMMENT ON COLUMN public.audit_log.actor_name IS
  'Naam zoals die bij het loggen in user_profiles stond; kopie, zodat de regel leesbaar blijft.';
COMMENT ON COLUMN public.audit_log.actor_role IS
  'Rol zoals die bij het loggen in user_profiles stond; scheidt planners van koeriers.';
COMMENT ON COLUMN public.audit_log.app_name IS
  'application_name van de sessie. Het ruwe bewijs onder source: daarop berust het onderscheid cron/sql.';

CREATE INDEX IF NOT EXISTS audit_log_occurred_at_idx ON public.audit_log (occurred_at DESC);
CREATE INDEX IF NOT EXISTS audit_log_actor_id_idx    ON public.audit_log (actor_id);
CREATE INDEX IF NOT EXISTS audit_log_shift_id_idx    ON public.audit_log (shift_id);
CREATE INDEX IF NOT EXISTS audit_log_courier_id_idx  ON public.audit_log (courier_id);
CREATE INDEX IF NOT EXISTS audit_log_table_name_idx  ON public.audit_log (table_name);
CREATE INDEX IF NOT EXISTS audit_log_txid_idx        ON public.audit_log (txid);

-- Dicht. Hier staan oude en nieuwe waarden van élke gelogde tabel in, dus ook
-- telefoonnummers, adressen en declaratiegegevens. Lezen gaat uitsluitend via
-- audit_log_list() hieronder, en die controleert zelf op superuser.
ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.audit_log FROM PUBLIC, anon, authenticated;


-- ────────────────────────────────────────────────────────────────────────
-- 2. Append-only afdwingen.
--
--    "Append-only" als afspraak is geen append-only. Zonder deze wacht kan een
--    regel die iemand niet bevalt met één UPDATE verdwijnen, en dan is het
--    logboek precies zoveel waard als de goede bedoelingen van wie toegang
--    heeft. TRUNCATE apart: een rij-trigger ziet die niet.
--
--    Opruimen van oude regels vergt dus een bewuste handeling: wacht eraf,
--    verwijderen, wacht erop. Dat is expres omslachtig.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.audit_log_is_append_only()
RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = public AS $fn$
BEGIN
  RAISE EXCEPTION 'audit_log is append-only: % is niet toegestaan.', TG_OP
    USING HINT = 'Opruimen? Zet audit_log_no_change en audit_log_no_truncate tijdelijk uit.';
END;
$fn$;

DROP TRIGGER IF EXISTS audit_log_no_change ON public.audit_log;
CREATE TRIGGER audit_log_no_change
  BEFORE UPDATE OR DELETE ON public.audit_log
  FOR EACH ROW EXECUTE FUNCTION public.audit_log_is_append_only();

DROP TRIGGER IF EXISTS audit_log_no_truncate ON public.audit_log;
CREATE TRIGGER audit_log_no_truncate
  BEFORE TRUNCATE ON public.audit_log
  FOR EACH STATEMENT EXECUTE FUNCTION public.audit_log_is_append_only();


-- ────────────────────────────────────────────────────────────────────────
-- 3. audit_capture — de triggerfunctie.
--
--    Eén functie voor alle tabellen. Alles wat per tabel verschilt wordt uit de
--    rij zelf gelezen via to_jsonb, zodat er geen lijst met kolomnamen is die
--    stilletjes achterloopt zodra iemand een kolom toevoegt.
--
--    DE HERKOMST — en waar die op berust:
--
--      app        auth.uid() is gevuld: iemand die ingelogd is, in de Planner
--                 of in de bezorg-app. actor_role zegt welke van de twee.
--
--      formulier  De token-pagina's (declaratie, meerwerk, BENU). LET OP: die
--                 praten NIET als anon met de database. De pagina stuurt de
--                 anon-sleutel naar een Edge Function, en die Edge Function
--                 roept de database aan met de service-role-sleutel. In de
--                 database is dat dus service_role, net als de mailverzender.
--                 Het onderscheid zit in request.path, dat PostgREST bij elke
--                 aanroep zet: de token-pagina's schrijven uitsluitend via de
--                 vijf RPC's in FORMULIER_RPCS. JWT-rol anon telt hier óók mee,
--                 voor het geval een pagina ooit rechtstreeks schrijft.
--
--      service    JWT-rol service_role, buiten die vijf RPC's: Edge Functions,
--                 waaronder alles wat pg_cron via net.http_post aftrapt.
--
--      cron       Geen JWT, en de sessie is van pg_cron. NIET af te leiden uit
--                 session_user: een cronjob draait als de gebruiker die hem
--                 inplande, en dat is hier postgres — net als de SQL Editor.
--                 pg_cron is wél te herkennen aan zijn sessie: in libpq-modus
--                 verbindt hij met application_name 'pg_cron', en in
--                 achtergrondwerker-modus heeft zijn backend in pg_stat_activity
--                 backend_type 'pg_cron'. Beide worden gecontroleerd. Zekerheid:
--                 redelijk, niet volledig — zie de cron-test onderaan.
--
--      sql        Geen JWT, geen pg_cron, en niet via PostgREST: directe
--                 databasetoegang, zoals de SQL Editor.
--
--      onbekend   Wat in geen van de vakjes past — bijvoorbeeld een aanroep via
--                 PostgREST zonder bruikbare JWT.
--
--    app_name wordt altijd ruw meegeschreven. Klopt de indeling hierboven ooit
--    niet, dan staat het bewijs om dat te zien in elke regel.
--
--    SECURITY DEFINER betekent dat current_user hier de EIGENAAR van de functie
--    is en niet de aanroeper. Daarom session_user, nooit current_user.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.audit_capture()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  -- Kolommen die niets zeggen over een inhoudelijke wijziging. Expliciet en geen
  -- patroon op '%_at': created_at, sent_at en responded_at zijn juist wél
  -- betekenisvol en mogen niet per ongeluk meegefilterd worden.
  NEGEER         CONSTANT TEXT[] := ARRAY['updated_at', 'modified_at', 'updated_on'];

  -- De RPC's waarlangs de token-pagina's schrijven (de Edge Functions
  -- shift-declaration, extra-work, benu-courier-form en benu-pharmacy-form).
  FORMULIER_RPCS CONSTANT TEXT[] := ARRAY[
    'declaration_submit', 'declaration_set_expenses',
    'extra_work_respond',
    'benu_entry_submit', 'benu_pharmacy_respond'];

  v_old     JSONB;
  v_new     JSONB;
  v_rec     JSONB;
  v_old_d   JSONB := '{}'::JSONB;
  v_new_d   JSONB := '{}'::JSONB;
  v_changed TEXT[] := ARRAY[]::TEXT[];
  v_key     TEXT;

  v_actor   UUID;
  v_name    TEXT;
  v_role    TEXT;
  v_source  TEXT;
  v_jwtrole TEXT;
  v_rpc     TEXT;
  v_app     TEXT;
  v_cron    BOOLEAN := false;

  v_rowid   TEXT;
  v_shift   UUID;
  v_courier UUID;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_new := to_jsonb(NEW);
  ELSIF TG_OP = 'DELETE' THEN
    v_old := to_jsonb(OLD);
  ELSE
    v_old := to_jsonb(OLD);
    v_new := to_jsonb(NEW);
  END IF;

  -- De VOLLEDIGE rij, vóór het terugsnoeien tot de gewijzigde velden hieronder:
  -- row_id, shift_id en courier_id moeten ook gevonden worden als ze zelf niet
  -- veranderden.
  v_rec := COALESCE(v_new, v_old);

  -- ── Alleen de gewijzigde velden bij een UPDATE ────────────────────────
  -- De hele rij twee keer wegschrijven maakt het logboek onleesbaar: bij een
  -- dienst met twintig kolommen moet een lezer zelf gaan vergelijken om te zien
  -- dat alleen de status veranderde.
  IF TG_OP = 'UPDATE' THEN
    FOR v_key IN SELECT jsonb_object_keys(v_new) LOOP
      CONTINUE WHEN v_key = ANY (NEGEER);
      IF (v_old -> v_key) IS DISTINCT FROM (v_new -> v_key) THEN
        v_changed := v_changed || v_key;
        v_old_d   := v_old_d || jsonb_build_object(v_key, v_old -> v_key);
        v_new_d   := v_new_d || jsonb_build_object(v_key, v_new -> v_key);
      END IF;
    END LOOP;

    -- Niets inhoudelijks veranderd — bijvoorbeeld een UPDATE die alleen
    -- updated_at bijzette. Geen regel: een logboek vol niet-wijzigingen maakt
    -- de echte wijzigingen onvindbaar.
    IF array_length(v_changed, 1) IS NULL THEN
      RETURN NULL;
    END IF;

    v_old := v_old_d;
    v_new := v_new_d;
  END IF;

  -- ── Wie ───────────────────────────────────────────────────────────────
  v_actor := auth.uid();
  IF v_actor IS NOT NULL THEN
    SELECT up.name, up.role INTO v_name, v_role
    FROM public.user_profiles up WHERE up.id = v_actor;
  END IF;

  v_app := NULLIF(current_setting('application_name', true), '');

  -- De JWT-claim en het pad apart afgeschermd: staat er onzin in die GUC's,
  -- dan mag dat geen logregel kosten.
  BEGIN
    v_jwtrole := NULLIF(current_setting('request.jwt.claims', true), '')::JSONB ->> 'role';
  EXCEPTION WHEN OTHERS THEN
    v_jwtrole := NULL;
  END;
  -- '/rpc/declaration_submit' → 'declaration_submit'. Via split_part en niet op
  -- het hele pad, zodat een voorvoegsel van de gateway er niet toe doet.
  v_rpc := NULLIF(split_part(COALESCE(current_setting('request.path', true), ''), '/rpc/', 2), '');

  IF v_actor IS NOT NULL THEN
    v_source := 'app';
  ELSIF v_jwtrole = 'anon' THEN
    v_source := 'formulier';
  ELSIF v_jwtrole = 'service_role' THEN
    v_source := CASE WHEN v_rpc = ANY (FORMULIER_RPCS) THEN 'formulier' ELSE 'service' END;
  ELSIF v_jwtrole IS NOT NULL THEN
    v_source := 'onbekend';
  ELSE
    -- Geen JWT. Alleen hier de catalogus in: dit is de zeldzame tak, en zo kost
    -- het gewone verkeer uit de Planner geen extra query.
    v_cron := v_app = 'pg_cron'
           OR EXISTS (SELECT 1 FROM pg_stat_activity
                      WHERE pid = pg_backend_pid() AND backend_type ILIKE 'pg_cron%');
    v_source := CASE
      WHEN v_cron                        THEN 'cron'
      -- Supabase Auth: een registratie zet via de trigger op auth.users een rij in
      -- user_profiles, zonder JWT. Dat is systeemverkeer, geen SQL Editor.
      WHEN session_user = 'supabase_auth_admin' THEN 'service'
      -- Via PostgREST maar zonder JWT: niet herleidbaar, en zeker geen SQL Editor.
      WHEN session_user = 'authenticator' THEN 'onbekend'
      ELSE 'sql'
    END;
  END IF;

  -- ── Welke rij ─────────────────────────────────────────────────────────
  -- 'id' waar die er is; anders de primaire sleutel uit de catalogus, zodat
  -- koppeltabellen als shift_pharmacies (shift_id, pharmacy_id) ook een
  -- bruikbare verwijzing krijgen.
  IF v_rec ? 'id' THEN
    v_rowid := v_rec ->> 'id';
  ELSE
    SELECT string_agg(v_rec ->> a.attname, '|' ORDER BY k.ord)
      INTO v_rowid
    FROM pg_index i
    JOIN LATERAL unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord) ON TRUE
    JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
    WHERE i.indrelid = TG_RELID AND i.indisprimary;
  END IF;

  -- Op shifts zelf is de dienst de rij; elders staat er een shift_id in.
  BEGIN
    v_shift := CASE
      WHEN TG_TABLE_NAME = 'shifts' THEN (v_rec ->> 'id')::UUID
      WHEN v_rec ? 'shift_id'       THEN (v_rec ->> 'shift_id')::UUID
    END;
  EXCEPTION WHEN OTHERS THEN
    v_shift := NULL;
  END;

  BEGIN
    v_courier := CASE WHEN v_rec ? 'courier_id' THEN (v_rec ->> 'courier_id')::UUID END;
  EXCEPTION WHEN OTHERS THEN
    v_courier := NULL;
  END;

  INSERT INTO public.audit_log (
    txid, actor_id, actor_name, actor_role, source, app_name,
    table_name, action, row_id, shift_id, courier_id,
    old_data, new_data, changed_fields)
  VALUES (
    txid_current(), v_actor, v_name, v_role, v_source, v_app,
    TG_TABLE_NAME, TG_OP, v_rowid, v_shift, v_courier,
    v_old, v_new, CASE WHEN TG_OP = 'UPDATE' THEN v_changed END);

  RETURN NULL;   -- AFTER-trigger: de retourwaarde doet niets

EXCEPTION WHEN OTHERS THEN
  -- Het logboek mag nooit een schrijfactie blokkeren. Zie de kop.
  RAISE WARNING '[audit] % op % niet gelogd: %', TG_OP, TG_TABLE_NAME, SQLERRM;
  RETURN NULL;
END;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 4. De triggers.
--
--    Via een lus en niet drieëntwintig keer uitgeschreven: dan staat de lijst op
--    één plek en kan hij niet half bijgewerkt raken. to_regclass() slaat tabellen
--    over die in deze database niet bestaan — dit schema wordt gedeeld, en een
--    migratie die klapt op een ontbrekende tabel van een andere app helpt
--    niemand.
--
--    BEWUST NIET gelogd:
--      mail_outbox, courier_announcements, shift_sms_log, declaration_reminders
--        — post en berichten. Die schrijven zichzelf vol bij elke verzendronde
--        en zeggen niets over een beslissing van een mens; hun eigen status is
--        in de tabel zelf na te lezen.
--      schedule_generation_state — een marker van de roostergenerator.
--      shift_time_reports — de bron van de kalibratie, geen handeling.
-- ────────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  t TEXT;
  TABELLEN CONSTANT TEXT[] := ARRAY[
    -- planning
    'shifts', 'shift_pharmacies', 'shift_institutions',
    'pharmacy_schedules', 'schedule_exceptions', 'holidays',
    -- mensen
    'employees', 'courier_contacts', 'user_profiles',
    'courier_pharmacy_access', 'courier_distances',
    -- stamgegevens (gedeeld met de bezorg-app)
    'pharmacies', 'institutions', 'groups',
    -- tarieven en instellingen
    'pharmacy_rates', 'reimbursement_rates', 'declaration_settings', 'invoice_settings',
    -- declaratie en meerwerk
    'shift_declarations', 'declaration_expenses', 'extra_work',
    -- BENU
    'benu_shift_entries', 'benu_pharmacy_entries'
  ];
BEGIN
  FOREACH t IN ARRAY TABELLEN LOOP
    IF to_regclass('public.' || t) IS NULL THEN
      RAISE NOTICE '[audit] tabel % bestaat niet, overgeslagen.', t;
      CONTINUE;
    END IF;
    EXECUTE format('DROP TRIGGER IF EXISTS audit_%1$s ON public.%1$I', t);
    EXECUTE format(
      'CREATE TRIGGER audit_%1$s AFTER INSERT OR UPDATE OR DELETE ON public.%1$I '
      'FOR EACH ROW EXECUTE FUNCTION public.audit_capture()', t);
  END LOOP;
END $$;


-- ────────────────────────────────────────────────────────────────────────
-- 5. is_superuser — in de stijl van is_privileged(), en daarnaast.
--
--    Bewust een eigen functie en geen verbreding of versmalling van
--    is_privileged(): die bewaakt tientallen RPC's die supervisors en admins
--    nodig hebben voor hun dagelijkse werk. Het logboek is een ander soort
--    toegang — wie het leest ziet wat collega's deden — en hoort bij één rol.
--
--    Met vaste search_path, anders dan het origineel uit migratie 001. Dat is
--    geen correctie van is_privileged() maar wel de reden om hem niet te kopiëren
--    zoals hij is.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.is_superuser()
RETURNS BOOLEAN
LANGUAGE sql SECURITY DEFINER STABLE SET search_path = public AS $fn$
  SELECT EXISTS (
    SELECT 1 FROM public.user_profiles
    WHERE id = auth.uid() AND role = 'superuser'
  );
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 6. Lezen: audit_log_list — een functie en geen SELECT-policy.
--
--    Waarom geen policy:
--      * Met een policy ligt de ruwe tabel open via PostgREST voor elke
--        superuser-sessie. Een gestolen sessie kan dan in één verzoek alle
--        oude en nieuwe waarden van alle tabellen exporteren. Deze functie
--        geeft hooguit 500 regels per keer en alleen de kolommen die het scherm
--        nodig heeft.
--      * Het scherm moet namen tonen van koeriers, apotheken en diensten —
--        ook als de rij inmiddels verwijderd is. Dat vergt joins op tabellen met
--        hun eigen RLS. Een SECURITY DEFINER-functie lost dat op één plek op.
--      * Filteren, pagineren en het tellen per transactie (voor "bevestigde 10
--        diensten") horen aan de serverkant; anders haalt het scherm alles op
--        om er honderd van te tonen.
--      * Het is de vorm van elk ander overzicht in de Planner
--        (extra_work_overview, declaration_overview).
--
--    De superuser-controle zit IN de functie en geeft een fout, geen lege
--    lijst: een supervisor die het probeert moet zien dat het niet mag, niet
--    denken dat er niets gebeurd is.
--
--    Pagineren op id en niet op occurred_at. occurred_at is now() en dus de
--    begintijd van de transactie: tien regels uit één bulkbevestiging delen die
--    tijd, en een cursor op de tijd zou er dan een paar overslaan.
--
--    tx_total telt de regels van dezelfde transactie BINNEN de filters, over
--    alle pagina's heen. Het scherm kan zo "bevestigde 500 diensten" zeggen
--    terwijl er pas honderd geladen zijn.
-- ────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.audit_log_list(
  TIMESTAMPTZ, TIMESTAMPTZ, TEXT[], UUID, TEXT, UUID, TEXT, BOOLEAN, BOOLEAN, BIGINT, INT);

CREATE FUNCTION public.audit_log_list(
  p_from      TIMESTAMPTZ,
  p_to        TIMESTAMPTZ,
  p_tables    TEXT[]  DEFAULT NULL,   -- de tabellen van een 'soort'; NULL = alles
  p_actor     UUID    DEFAULT NULL,   -- één persoon
  p_source    TEXT    DEFAULT NULL,   -- één bron, bijvoorbeeld 'sql'
  p_courier   UUID    DEFAULT NULL,   -- één koerier
  p_search    TEXT    DEFAULT NULL,   -- vrije tekst
  p_couriers  BOOLEAN DEFAULT false,  -- ook koeriers en formulieren
  p_system    BOOLEAN DEFAULT false,  -- ook service en cron
  p_before_id BIGINT  DEFAULT NULL,   -- "meer laden": alleen regels vóór deze
  p_limit     INT     DEFAULT 100
)
RETURNS TABLE (
  id                   BIGINT,
  occurred_at          TIMESTAMPTZ,
  txid                 BIGINT,
  tx_total             BIGINT,
  actor_id             UUID,
  actor_name           TEXT,
  actor_role           TEXT,
  source               TEXT,
  app_name             TEXT,
  table_name           TEXT,
  action               TEXT,
  row_id               TEXT,
  shift_id             UUID,
  courier_id           UUID,
  courier_name         TEXT,
  old_courier_name     TEXT,
  pharmacy_name        TEXT,
  shift_date           TEXT,
  shift_start          TEXT,
  shift_pharmacy_names TEXT,
  old_data             JSONB,
  new_data             JSONB,
  changed_fields       TEXT[]
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  PLANNERS CONSTANT TEXT[] := ARRAY['superuser', 'supervisor', 'admin'];
  v_search TEXT := lower(NULLIF(btrim(COALESCE(p_search, '')), ''));
BEGIN
  IF NOT public.is_superuser() THEN
    RAISE EXCEPTION 'Het logboek is alleen in te zien door een superuser.'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH f AS (
    SELECT a.*,
           count(*) OVER (PARTITION BY a.txid) AS tx_total
    FROM public.audit_log a
    LEFT JOIN public.user_profiles cu ON cu.id = a.courier_id
    WHERE a.occurred_at >= p_from
      AND a.occurred_at <  p_to
      AND (p_tables IS NULL OR a.table_name = ANY (p_tables))
      AND (p_actor  IS NULL OR a.actor_id = p_actor)
      AND (p_source IS NULL OR a.source = p_source)
      -- De koerier van de rij zelf, of de koerier die nú op de dienst staat. Dat
      -- tweede vangt shift_pharmacies en shift_declarations-regels die geen
      -- courier_id dragen maar wel over zijn dienst gaan.
      AND (p_courier IS NULL
           OR a.courier_id = p_courier
           OR a.shift_id IN (SELECT s.id FROM public.shifts s WHERE s.courier_id = p_courier))
      -- Wie er standaard te zien is: planners, en alles wat buiten de app om
      -- ging. 'onbekend' hoort daarbij: een herkomst die niet te herleiden is,
      -- is precies het soort regel waarom dit logboek bestaat.
      AND (
            (a.source = 'app' AND a.actor_role = ANY (PLANNERS))
         OR a.source IN ('sql', 'onbekend')
         OR (p_couriers AND (a.source = 'formulier'
                             OR (a.source = 'app'
                                 AND (a.actor_role IS NULL OR a.actor_role <> ALL (PLANNERS)))))
         OR (p_system AND a.source IN ('service', 'cron'))
      )
      -- strpos en geen ILIKE: een % of _ in het zoekveld moet een letter zijn,
      -- geen jokerteken.
      AND (v_search IS NULL
           OR strpos(lower(COALESCE(a.actor_name, '')), v_search) > 0
           OR strpos(lower(COALESCE(cu.name, '')),      v_search) > 0
           OR strpos(lower(a.table_name),               v_search) > 0
           OR strpos(lower(COALESCE(a.row_id, '')),     v_search) > 0
           OR strpos(lower(COALESCE(a.old_data::TEXT, '')), v_search) > 0
           OR strpos(lower(COALESCE(a.new_data::TEXT, '')), v_search) > 0)
  )
  SELECT
    f.id, f.occurred_at, f.txid, f.tx_total,
    f.actor_id, f.actor_name, f.actor_role, f.source, f.app_name,
    f.table_name, f.action, f.row_id, f.shift_id, f.courier_id,
    -- Namen voor weergave. Gaat de rij over een profiel zelf, dan het profiel
    -- achter row_id — bij een rolwijziging staat de naam niet in de diff — en
    -- bestaat dat niet meer, dan uit de gelogde rij.
    -- De koerier van de rij zelf; anders die van de dienst — extra_work en
    -- shift_pharmacies hebben geen eigen courier_id, maar gaan wel over iemands
    -- dienst. Bij een verwijderde dienst die uit de verwijderregel.
    COALESCE(cu.name, sc.name,
             CASE WHEN f.table_name = 'user_profiles'
                  THEN COALESCE((SELECT u2.name FROM public.user_profiles u2 WHERE u2.id::TEXT = f.row_id),
                                f.old_data ->> 'name', f.new_data ->> 'name') END),
    CASE WHEN 'courier_id' = ANY (COALESCE(f.changed_fields, ARRAY[]::TEXT[]))
         THEN (SELECT oc.name FROM public.user_profiles oc
               WHERE oc.id::TEXT = f.old_data ->> 'courier_id') END,
    COALESCE(ph.name,
             CASE WHEN f.table_name = 'pharmacies'
                  THEN COALESCE(f.old_data ->> 'name', f.new_data ->> 'name') END),
    -- Datum en tijd van de dienst: uit de dienst zoals hij nu is; anders uit de
    -- gelogde rij zelf; en is de dienst inmiddels verwijderd, uit de regel die
    -- dat vastlegde. Zonder die laatste stap leest de bevestiging van een dienst
    -- die later is weggehaald als "bevestigde dienst" — zonder te zeggen welke.
    COALESCE(s.shift_date::TEXT,
             CASE WHEN f.table_name = 'shifts'
                  THEN COALESCE(f.old_data ->> 'shift_date', f.new_data ->> 'shift_date') END,
             gone.old_data ->> 'shift_date'),
    COALESCE(to_char(s.start_time, 'HH24:MI'),
             CASE WHEN f.table_name = 'shifts'
                  THEN left(COALESCE(f.old_data ->> 'start_time', f.new_data ->> 'start_time'), 5) END,
             left(gone.old_data ->> 'start_time', 5)),
    (SELECT string_agg(p2.name, ', ' ORDER BY p2.name)
       FROM public.shift_pharmacies sp
       JOIN public.pharmacies p2 ON p2.id = sp.pharmacy_id
      WHERE sp.shift_id = f.shift_id),
    f.old_data, f.new_data, f.changed_fields
  FROM f
  LEFT JOIN public.user_profiles cu ON cu.id = f.courier_id
  LEFT JOIN public.shifts s         ON s.id  = f.shift_id
  -- De verwijderregel van de dienst, alleen als de dienst er niet meer is.
  LEFT JOIN LATERAL (
    SELECT x.old_data FROM public.audit_log x
    WHERE s.id IS NULL AND f.shift_id IS NOT NULL
      AND x.table_name = 'shifts' AND x.action = 'DELETE' AND x.shift_id = f.shift_id
    ORDER BY x.id DESC LIMIT 1
  ) gone ON TRUE
  LEFT JOIN public.user_profiles sc ON sc.id = COALESCE(
      s.courier_id, NULLIF(gone.old_data ->> 'courier_id', '')::UUID)
  -- De apotheek. Bij een wijziging staat pharmacy_id niet in de diff als hij zelf
  -- niet veranderde; voor de drie tabellen waar dat het vaakst voorkomt halen we
  -- hem dan uit de rij zoals die nu is. Bij meerwerk is dat geen detail: de
  -- apotheek ís de klant aan wie het verzoek ging.
  LEFT JOIN public.pharmacies ph    ON ph.id = COALESCE(
      f.new_data ->> 'pharmacy_id', f.old_data ->> 'pharmacy_id',
      CASE f.table_name
        WHEN 'pharmacies'         THEN f.row_id
        WHEN 'extra_work'         THEN (SELECT x.pharmacy_id FROM public.extra_work x         WHERE x.id::TEXT = f.row_id)
        WHEN 'pharmacy_schedules' THEN (SELECT x.pharmacy_id FROM public.pharmacy_schedules x WHERE x.id::TEXT = f.row_id)
        WHEN 'pharmacy_rates'     THEN (SELECT x.pharmacy_id FROM public.pharmacy_rates x     WHERE x.id::TEXT = f.row_id)
      END)
  WHERE p_before_id IS NULL OR f.id < p_before_id
  ORDER BY f.id DESC
  LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
END;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 7. audit_log_actors — de keuzelijst "wie".
--    Uit het logboek zelf en niet uit user_profiles: zo staat er ook iemand in
--    die inmiddels geen profiel meer heeft, en niemand die in de periode niets
--    deed.
-- ────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.audit_log_actors(TIMESTAMPTZ, TIMESTAMPTZ);

CREATE FUNCTION public.audit_log_actors(p_from TIMESTAMPTZ, p_to TIMESTAMPTZ)
RETURNS TABLE (actor_id UUID, actor_name TEXT, actor_role TEXT, regels BIGINT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF NOT public.is_superuser() THEN
    RAISE EXCEPTION 'Het logboek is alleen in te zien door een superuser.'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT a.actor_id, max(a.actor_name), max(a.actor_role), count(*)
  FROM public.audit_log a
  WHERE a.actor_id IS NOT NULL
    AND a.occurred_at >= p_from AND a.occurred_at < p_to
  GROUP BY a.actor_id
  ORDER BY max(a.actor_name);
END;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 8. Rechten.
--    De leesfuncties zijn uit te voeren door authenticated; de controle op
--    superuser zit erin. De triggerfuncties zijn door niemand rechtstreeks aan te
--    roepen.
-- ────────────────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.audit_capture()            FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.audit_log_is_append_only() FROM PUBLIC, anon, authenticated;

REVOKE ALL     ON FUNCTION public.is_superuser() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.is_superuser() TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.audit_log_list(
  TIMESTAMPTZ, TIMESTAMPTZ, TEXT[], UUID, TEXT, UUID, TEXT, BOOLEAN, BOOLEAN, BIGINT, INT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.audit_log_list(
  TIMESTAMPTZ, TIMESTAMPTZ, TEXT[], UUID, TEXT, UUID, TEXT, BOOLEAN, BOOLEAN, BIGINT, INT)
  TO authenticated;

REVOKE ALL     ON FUNCTION public.audit_log_actors(TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.audit_log_actors(TIMESTAMPTZ, TIMESTAMPTZ) TO authenticated;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie
-- ────────────────────────────────────────────────────────────────────────

-- Verwacht: 23 triggers, één per tabel uit de lijst in punt 4. Op de functie en
-- niet op de naam: audit_log_no_change begint ook met 'audit_' en hoort hier
-- niet mee te tellen.
SELECT count(*) AS triggers
FROM pg_trigger
WHERE NOT tgisinternal AND tgfoid = 'public.audit_capture()'::REGPROCEDURE;

-- Welke tabellen gelogd worden. Loop deze lijst na tegen punt 4.
SELECT c.relname AS tabel
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
WHERE NOT t.tgisinternal AND t.tgfoid = 'public.audit_capture()'::REGPROCEDURE
ORDER BY c.relname;

-- Verwacht: 0. audit_log heeft geen foreign keys — zie de toelichting bij punt 1.
-- Een FK zou bij het verwijderen van een dienst of profiel een UPDATE of DELETE
-- op audit_log veroorzaken, en dan klapt dat verwijderen op de append-only-wacht.
SELECT count(*) AS foreign_keys
FROM pg_constraint
WHERE conrelid = 'public.audit_log'::REGCLASS AND contype = 'f';

-- Verwacht: false. In de SQL Editor is er geen ingelogde gebruiker.
SELECT public.is_superuser() AS ben_ik_superuser;

-- Een proefrit. Zet een dienst op zijn eigen status — dat is geen inhoudelijke
-- wijziging, dus er hoort GEEN regel bij te komen. (Vervang het id.)
-- UPDATE public.shifts SET status = status WHERE id = '<uuid>';
-- SELECT count(*) FROM public.audit_log WHERE row_id = '<uuid>';   -- verwacht: 0

-- Append-only. Alle drie horen te klappen.
-- UPDATE public.audit_log SET source = 'app' WHERE id = 1;
-- DELETE FROM public.audit_log WHERE id = 1;
-- TRUNCATE public.audit_log;

-- ── Test: cron tegenover SQL Editor ──────────────────────────────────────
-- Dit is de proef op de herkenning van pg_cron (zie punt 3). Draai hem NA de
-- COMMIT, als losse stappen in de SQL Editor.
--
-- Stap 1. Een cronjob die één keer een testfeestdag in 2099 aanmaakt, hem weer
-- weghaalt, en zichzelf uitschrijft. Netto verandert er niets: alles gebeurt in
-- één transactie, en 2099 valt ver buiten elk roostervenster.
--
-- SELECT cron.schedule('audit-test-cron', '* * * * *', $job$
--   INSERT INTO public.holidays (holiday_date, name) VALUES ('2099-12-30', 'audit-test cron');
--   DELETE FROM public.holidays WHERE holiday_date = '2099-12-30';
--   SELECT cron.unschedule('audit-test-cron');
-- $job$);
--
-- Stap 2. Hetzelfde met de hand, op een andere datum zodat de twee elkaar niet
-- raken als ze toevallig gelijk lopen.
--
-- INSERT INTO public.holidays (holiday_date, name) VALUES ('2099-12-31', 'audit-test sql');
-- DELETE FROM public.holidays WHERE holiday_date = '2099-12-31';
--
-- Stap 3. Na een à twee minuten, naast elkaar. Verwacht vier regels: twee met
-- source 'cron' en twee met source 'sql'. app_name laat zien waar het
-- onderscheid op berust.
--
-- SELECT occurred_at, source, app_name, action,
--        COALESCE(new_data, old_data) ->> 'name' AS wat
-- FROM public.audit_log
-- WHERE table_name = 'holidays'
--   AND COALESCE(new_data, old_data) ->> 'name' LIKE 'audit-test%'
-- ORDER BY id;
--
-- Stap 4. Staat er bij de cronregels 'sql', dan herkent audit_capture() deze
-- installatie van pg_cron niet. Draai dan deze query terwijl een cronjob loopt
-- (de extra-work-sweep draait op :30) en kijk wat pg_cron in deze database als
-- herkenning achterlaat:
--
-- SELECT pid, backend_type, application_name, usename
-- FROM pg_stat_activity
-- WHERE backend_type ILIKE '%cron%' OR application_name ILIKE '%cron%';
--
-- En controleer dat de job weg is (verwacht: geen rij):
-- SELECT jobid, jobname FROM cron.job WHERE jobname = 'audit-test-cron';

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
