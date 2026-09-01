-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — factuursplitsing keten / filiaal — migratie 032
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 031 eerst.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien, en draai daarna       │
-- │ supabase/tests/032_chain_split_test.sql.                               │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAT DIT DOET
--   Gebudgetteerde uren naar de keten, meerwerk naar het filiaal. Per keten in
--   te schakelen, en STANDAARD UIT: zolang niemand hem aanzet gaat alles naar
--   het filiaal en verandert er geen cent aan een bestaande factuur.
--
-- ┌─ DRIE KEUZES DIE IK HEB GEMAAKT ───────────────────────────────────────┐
-- │ Ze staan hier omdat ze commercieel zijn en niet technisch. Alle drie    │
-- │ zijn omkeerbaar zolang de splitsing uit staat.                          │
-- │                                                                        │
-- │ 1. HET BUDGET IS EEN GERESERVEERD BLOK — maar alleen bij een keten met  │
-- │    de splitsing aan. De keten betaalt altijd de volle gebudgetteerde     │
-- │    uren, ook als de koerier eerder klaar is; het filiaal betaalt alleen  │
-- │    de uitloop.                                                          │
-- │                                                                        │
-- │    DIT IS EEN VARIANT, GEEN NIEUWE HOOFDREGEL. Staat de splitsing uit —  │
-- │    en dat is overal de standaard — dan geldt onverkort wat er stond:     │
-- │    werkelijke uren, in beide richtingen, geen ondergrens en geen         │
-- │    plafond (fase 7). Geval 3 van 025_pharmacy_invoicing_test.sql moet    │
-- │    dus gewoon blijven slagen, en geval 9 hieronder bewaakt dat het niet  │
-- │    stiekem toch overal gaat gelden.                                     │
-- │                                                                        │
-- │    Gevolg om te kennen: bij een gesplitste keten kan het regeltotaal     │
-- │    hoger uitvallen dan bij dezelfde dienst zonder splitsing, namelijk    │
-- │    als er korter gewerkt is. billed_minutes blijft tonen wat er          │
-- │    werkelijk gewerkt is, dus het verschil is zichtbaar.                  │
-- │                                                                        │
-- │ 2. HET STARTTARIEF gaat mee naar de keten. Het hoort bij de afgesproken │
-- │    opdracht, niet bij wat er die dag misging.                           │
-- │                                                                        │
-- │ 3. REISKOSTEN EN ONKOSTEN gaan naar het FILIAAL. Ze horen bij de rit    │
-- │    die daar gereden is en variëren per keer; het pakket dat de keten    │
-- │    koopt is de tijd, niet het parkeergeld.                              │
-- │                                                                        │
-- │    De regel in één zin: het geplande pakket naar de keten, alles wat    │
-- │    daarvan afwijkt naar het filiaal.                                    │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAT NIET VERANDERT
--   De goedkeuringslus. Het meerwerk hoort bij het filiaal dat het veroorzaakte
--   en daar gaat de mail al heen; extra_work draagt zijn eigen pharmacy_id. De
--   splitsing bepaalt alleen op wélke factuur de uren landen, niet wie erover
--   beslist.
--
--   Ook niet: declaration_compute(), de nadeclaratieketen en de uitbetaling aan
--   de koerier. Die staan hier volledig los van.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────
-- 1. De ketenlaag krijgt twee velden.
--    groups is gedeeld met de bezorg-app (fetchGroups() in App.tsx en
--    PharmacyOverview.tsx, beheerd via groups-admin.ts). Additief en met een
--    default, dus voor die app verandert er niets.
-- ────────────────────────────────────────────────────────────────────────
ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS split_extra_work BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE public.groups
  ADD COLUMN IF NOT EXISTS billing_email TEXT;

ALTER TABLE public.groups
  DROP CONSTRAINT IF EXISTS groups_billing_email_chk;
ALTER TABLE public.groups
  ADD CONSTRAINT groups_billing_email_chk
  CHECK (billing_email IS NULL OR position('@' in billing_email) > 1);

COMMENT ON COLUMN public.groups.split_extra_work IS
  'Aan = de gebudgetteerde uren van deze keten gaan naar het centrale adres en '
  'het goedgekeurde meerwerk naar het filiaal (migratie 032). Uit = alles naar '
  'het filiaal, zoals het altijd was.';

GRANT SELECT (split_extra_work, billing_email) ON public.groups TO authenticated;

-- Het factuurscherm moet weten welke apotheken bij een keten horen. Staan er op
-- deze gedeelde tabel kolomrechten in plaats van één tabelrecht, dan valt
-- "groupId" daarbuiten; expliciet toekennen is in beide gevallen goed.
GRANT SELECT ("groupId") ON public.pharmacies TO authenticated;


-- ────────────────────────────────────────────────────────────────────────
-- 2. De keten van een apotheek.
--    pharmacies."groupId" is camelCase en heeft dus dubbele quotes nodig; dat is
--    precies het soort ding dat je één keer op één plek wilt opschrijven.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.pharmacy_chain(p_pharmacy_id TEXT)
RETURNS public.groups
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT g.* FROM public.pharmacies p
  JOIN public.groups g ON g.id = p."groupId"
  WHERE p.id = p_pharmacy_id;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 3. Beheer: het centrale adres en de schakelaar.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_group_billing(
  p_group_id TEXT, p_email TEXT, p_split BOOLEAN
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_email TEXT := NULLIF(btrim(COALESCE(p_email, '')), '');
BEGIN
  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'Alleen planners mogen de facturatie van een keten instellen.';
  END IF;

  -- De splitsing aanzetten zonder centraal adres levert facturen op die nergens
  -- heen kunnen. Liever hier weigeren dan later een keten-factuur zonder
  -- geadresseerde.
  IF p_split AND v_email IS NULL THEN
    RAISE EXCEPTION 'Vul eerst een centraal factuuradres in voordat je de splitsing aanzet.'
      USING ERRCODE = '45011';
  END IF;

  UPDATE public.groups
     SET billing_email = v_email,
         split_extra_work = COALESCE(p_split, false)
   WHERE id = p_group_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Geen keten met id %.', p_group_id;
  END IF;
END;
$fn$;

-- De ketens met hun instelling, plus hoeveel apotheken eraan hangen.
CREATE OR REPLACE FUNCTION public.chain_overview()
RETURNS TABLE (
  group_id         TEXT,
  group_name       TEXT,
  billing_email    TEXT,
  split_extra_work BOOLEAN,
  pharmacies       INT
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT g.id, g.name, g.billing_email, g.split_extra_work,
         (SELECT count(*)::INT FROM public.pharmacies p WHERE p."groupId" = g.id)
  FROM public.groups g
  WHERE public.is_privileged()
  ORDER BY g.name;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 4. De meerwerkmail moet zeggen op wélke factuur die uren landen.
--    Zodra het budget naar de keten gaat, betaalt het filiaal alleen de uitloop
--    — en dan is "we belasten de extra tijd door" te vaag: de lezer denkt aan de
--    factuur die hij van zijn keten kent. Body uit migratie 031, met één veld
--    erbij in de payload.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.extra_work_release(
  p_id UUID, p_planner_note TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_row   public.extra_work;
  v_cfg   public.invoice_settings;
  v_email TEXT;
  v_shift public.shifts;
  v_note  TEXT;
  v_chain public.groups;
BEGIN
  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'Alleen planners mogen meerwerk vrijgeven.';
  END IF;

  SELECT * INTO v_row FROM public.extra_work WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Geen meerwerkmelding met id %.', p_id;
  END IF;
  IF v_row.status <> 'new' THEN
    RAISE EXCEPTION 'Deze melding is al vrijgegeven of afgehandeld (%).', v_row.status;
  END IF;

  SELECT billing_email INTO v_email FROM public.pharmacies WHERE id = v_row.pharmacy_id;
  IF v_email IS NULL THEN
    RAISE EXCEPTION 'Deze apotheek heeft geen e-mailadres. Vul dat eerst in bij Apotheken.'
      USING ERRCODE = '45010';
  END IF;

  SELECT * INTO v_cfg   FROM public.invoice_settings WHERE id;
  SELECT * INTO v_shift FROM public.shifts WHERE id = v_row.shift_id;
  v_chain := public.pharmacy_chain(v_row.pharmacy_id);

  v_note := COALESCE(NULLIF(btrim(COALESCE(p_planner_note, '')), ''), v_row.courier_note);

  UPDATE public.extra_work SET
    status       = 'released',
    planner_note = v_note,
    released_at  = now(),
    released_by  = auth.uid(),
    respond_by   = now() + make_interval(hours => v_cfg.extra_work_respond_hours),
    token_hash   = public.declaration_hash_token(public.declaration_new_token()),
    token_expires_at = now() + make_interval(hours => v_cfg.extra_work_respond_hours) + INTERVAL '30 days'
  WHERE id = p_id;

  INSERT INTO public.mail_outbox (
    courier_id, recipient_override, kind, subject_type, subject_id, payload)
  VALUES (
    NULL, v_email, 'extra_work_request', 'shift', v_row.shift_id,
    jsonb_build_object(
      'extra_work_id',  v_row.id,
      'pharmacy_name',  (SELECT name FROM public.pharmacies WHERE id = v_row.pharmacy_id),
      'shift_date',     v_shift.shift_date,
      'weekday',        EXTRACT(ISODOW FROM v_shift.shift_date),
      'planned_start',  to_char(v_shift.start_time, 'HH24:MI'),
      'planned_end',    to_char(v_shift.budgeted_end_time, 'HH24:MI'),
      'extra_minutes',  v_row.share_minutes,
      'respond_hours',  v_cfg.extra_work_respond_hours,
      -- Alleen bij een gesplitste keten: dan komt déze tijd op de eigen factuur
      -- van het filiaal en niet op die van de keten.
      'own_invoice',    COALESCE(v_chain.split_extra_work, false),
      'note',           v_note));
END;
$fn$;

REVOKE ALL     ON FUNCTION public.extra_work_release(UUID, TEXT) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.extra_work_release(UUID, TEXT) TO authenticated, service_role;


-- ────────────────────────────────────────────────────────────────────────
-- 5. invoice_lines — de splitsing erin.
--    Body uit migratie 031, met vijf kolommen erbij. Nieuwe kolommen, dus DROP
--    en CREATE; de rechten staan er onderaan weer.
--
--    De bestaande kolommen houden hun betekenis: line_total blijft het TOTAAL
--    voor deze dienst bij deze apotheek. chain_amount en branch_amount zeggen
--    hoe dat totaal over de twee facturen verdeeld wordt, en tellen samen op tot
--    line_total. Zo verandert er niets aan wat er al gelezen wordt.
--
--    Er is bewust GEEN invoice_lines_for_chain(): een functie die dezelfde vorm
--    teruggeeft zou een eigen composiet type vergen, en dan moet invoice_lines
--    van RETURNS TABLE naar RETURNS SETOF <type> — een herschrijving van de
--    functie die inmiddels vijf migraties lang zorgvuldig is doorgegeven, voor
--    een lus over een handvol apotheken. Het factuurscherm telt de ketenkolom
--    zelf op over de filialen van die keten.
-- ────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.invoice_lines(TEXT, DATE, DATE);

CREATE OR REPLACE FUNCTION public.invoice_lines(
  p_pharmacy_id TEXT, p_from DATE, p_to DATE
)
RETURNS TABLE (
  shift_id              UUID,
  shift_date            DATE,
  shift_type            TEXT,
  courier_name          TEXT,
  pharmacies_in_shift   INT,
  planned_minutes       INT,
  share_pct             NUMERIC,
  shift_planned_minutes INT,
  shift_actual_minutes  INT,
  billed_minutes        NUMERIC,
  from_declaration      BOOLEAN,
  hourly_rate           NUMERIC,
  rate_id               UUID,
  hours_amount          NUMERIC,
  start_amount          NUMERIC,
  travel_amount         NUMERIC,
  expenses_amount       NUMERIC,
  -- Meerwerk (migratie 031). approved en expired leveren allebei een
  -- factuurregel op, maar moeten uit elkaar te houden zijn: bij expired heeft
  -- nooit iemand gekeken, en dáár komt discussie uit voort.
  extra_work_status     TEXT,
  extra_work_minutes    NUMERIC,
  -- Factuursplitsing keten/filiaal (migratie 032). Staat de splitsing uit,
  -- dan is chain_amount 0 en branch_amount het hele bedrag: precies zoals
  -- het altijd was.
  chain_id              TEXT,
  chain_name            TEXT,
  split_active          BOOLEAN,
  chain_amount          NUMERIC,
  branch_amount         NUMERIC,
  urgent_amount         NUMERIC,
  urgent_note           TEXT,
  line_total            NUMERIC,
  incomplete            BOOLEAN,
  reason                TEXT
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cfg      public.invoice_settings;
  r          RECORD;
  v_rate     public.pharmacy_rates;
  v_reasons  TEXT[];
  v_n        INT;
  v_sum      INT;
  v_missing  BOOLEAN;
  v_share    NUMERIC;
  v_planned  INT;
  v_actual   INT;
  v_minutes  NUMERIC;
  v_billed   NUMERIC;
  v_travel   NUMERIC;
  v_expenses NUMERIC;
  -- Het uurtarief dat bij DEZE dienst hoort. Sinds migratie 030 hangt dat
  -- van het diensttype af, en bij een reguliere dienst van het vervoermiddel.
  v_hourly   NUMERIC;
  v_kind     TEXT;    -- waar het tarief vandaan kwam, voor de melding
  v_capped   NUMERIC; -- te factureren minuten, na aftrek van niet-goedgekeurd meerwerk
  v_chain    public.groups;
  v_split    BOOLEAN;
  v_plan_min NUMERIC; -- het gereserveerde blok van deze apotheek, in minuten
  v_chain_min  NUMERIC;
  v_branch_min NUMERIC;

  v_dev      NUMERIC;
BEGIN
  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'Alleen planners mogen factuurregels opvragen.';
  END IF;

  SELECT * INTO v_cfg FROM public.invoice_settings WHERE id;

  -- Wie krijgt de rekening (migratie 032). Eén keer opzoeken: de apotheek is
  -- voor de hele aanroep dezelfde, en dan hoort dit niet in de lus.
  v_chain := public.pharmacy_chain(p_pharmacy_id);
  v_split := COALESCE(v_chain.split_extra_work, false);

  FOR r IN
    SELECT s.id, s.shift_date, s.shift_type, s.transport_mode,
           s.start_time, s.budgeted_end_time,
           s.urgent_amount, s.urgent_note,
           up.name AS courier_name,
           sp.budgeted_minutes,
           (SELECT count(*) FROM public.shift_pharmacies x WHERE x.shift_id = s.id) AS n_pharmacies,
           (SELECT sum(x.budgeted_minutes) FROM public.shift_pharmacies x WHERE x.shift_id = s.id) AS sum_minutes,
           EXISTS (SELECT 1 FROM public.shift_pharmacies x
                    WHERE x.shift_id = s.id AND x.budgeted_minutes IS NULL) AS any_missing,
           d.actual_start, d.actual_end, d.claims_travel,
           d.computed_reimbursable_km, rr.rate_per_km,
           (SELECT sum(e.amount_eur) FROM public.declaration_expenses e
             WHERE e.declaration_id = d.id) AS expense_total,
           xw.status        AS extra_status,
           xw.share_minutes AS extra_share_minutes
    FROM public.shift_pharmacies sp
    JOIN public.shifts s              ON s.id = sp.shift_id
    LEFT JOIN public.user_profiles up ON up.id = s.courier_id
    LEFT JOIN public.shift_declarations d ON d.shift_id = s.id
    LEFT JOIN public.reimbursement_rates rr ON rr.id = d.rate_id
    LEFT JOIN public.extra_work xw
      ON xw.shift_id = s.id AND xw.pharmacy_id = sp.pharmacy_id
    WHERE sp.pharmacy_id = p_pharmacy_id
      AND s.status <> 'draft'
      AND (p_from IS NULL OR s.shift_date >= p_from)
      AND (p_to   IS NULL OR s.shift_date <= p_to)
    ORDER BY s.shift_date, s.start_time
  LOOP
    v_reasons := ARRAY[]::TEXT[];
    v_n       := r.n_pharmacies;
    v_sum     := r.sum_minutes;
    v_missing := r.any_missing;

    -- ── Het aandeel van deze apotheek ──────────────────────────────────
    IF v_n <= 1 THEN
      v_share := 1;
    ELSIF v_missing OR v_sum IS NULL OR v_sum = 0 THEN
      v_share := 1::NUMERIC / v_n;
      v_reasons := v_reasons || format(
        'geen geplande minuten vastgelegd; gelijk verdeeld over %s apotheken', v_n);
    ELSE
      v_share := r.budgeted_minutes::NUMERIC / v_sum;
    END IF;

    -- ── Duur: gepland en werkelijk ─────────────────────────────────────
    v_planned := CASE WHEN r.budgeted_end_time IS NULL THEN NULL ELSE
      (EXTRACT(EPOCH FROM (r.budgeted_end_time - r.start_time
        + CASE WHEN r.budgeted_end_time <= r.start_time THEN INTERVAL '1 day' ELSE INTERVAL '0' END)) / 60)::INT
    END;

    v_actual := CASE WHEN r.actual_start IS NULL OR r.actual_end IS NULL THEN NULL ELSE
      (EXTRACT(EPOCH FROM (r.actual_end - r.actual_start
        + CASE WHEN r.actual_end <= r.actual_start THEN INTERVAL '1 day' ELSE INTERVAL '0' END)) / 60)::INT
    END;

    -- ::TEXT op elke vaste zin. Zonder dat kiest Postgres mogelijk
    -- anyarray || anyarray en leest hij de zin als array-literaal — zie punt 1
    -- in de kop van dit bestand.
    IF v_actual IS NULL THEN
      v_minutes := v_planned;
      IF v_planned IS NULL THEN
        v_reasons := v_reasons || 'geen werkelijke duur en geen geplande eindtijd; niets te factureren'::TEXT;
      ELSE
        v_reasons := v_reasons || 'geen ingevulde declaratie; geplande uren gefactureerd'::TEXT;
      END IF;
    ELSE
      v_minutes := v_actual;
      IF v_planned IS NOT NULL AND v_planned > 0 THEN
        v_dev := abs(v_actual - v_planned)::NUMERIC / v_planned * 100;
        IF v_dev > v_cfg.deviation_pct THEN
          v_reasons := v_reasons || format(
            'werkelijke duur wijkt %s%% af van gepland (%s vs %s minuten)',
            round(v_dev), v_actual, v_planned);
        END IF;
      END IF;
    END IF;

    -- Onbekend blijft onbekend: geen duur is niet nul minuten. Zou hier 0
    -- staan, dan levert de regel een keurig ogend totaal van alleen het
    -- starttarief op — te weinig, en niet als zodanig herkenbaar.
    v_billed := CASE WHEN v_minutes IS NULL THEN NULL ELSE round(v_minutes * v_share, 2) END;

    -- ── Meerwerk: wachten op de klant (migratie 031) ───────────────────
    --    Alleen goedgekeurd of verlopen meerwerk gaat op de factuur. Staat het
    --    nog open of is het betwist, dan factureren we het GEPLANDE deel en
    --    blijft de uitloop eruit. Dat is de conservatieve kant: te weinig
    --    factureren corrigeer je met een telefoontje, te veel kost vertrouwen.
    --
    --    Dit raakt UITSLUITEND de factuur. De koerier wordt in alle gevallen
    --    gewoon uitbetaald via de nadeclaratieketen — een geschil met de klant
    --    is een geschil tussen Greenspeed en de apotheek.
    v_capped := v_billed;
    IF r.extra_status IS NOT NULL AND v_billed IS NOT NULL
       AND r.extra_status NOT IN ('approved', 'expired') THEN
      v_capped := greatest(v_billed - COALESCE(r.extra_share_minutes, 0), 0);
      v_reasons := v_reasons || CASE r.extra_status
        WHEN 'disputed' THEN 'meerwerk betwist door de apotheek; alleen de geplande uren gefactureerd'::TEXT
        WHEN 'released' THEN 'meerwerk ligt bij de apotheek; alleen de geplande uren gefactureerd'::TEXT
        ELSE 'meerwerk nog niet vrijgegeven; alleen de geplande uren gefactureerd'::TEXT
      END;
    ELSIF r.extra_status = 'expired' THEN
      v_reasons := v_reasons || 'meerwerk niet beantwoord binnen de termijn; wel gefactureerd'::TEXT;
    END IF;

    -- ── Tarief ─────────────────────────────────────────────────────────
    v_rate := public.pharmacy_rate_on(p_pharmacy_id, r.shift_date);

    -- ── Welk uurtarief hoort hierbij (migratie 030) ────────────────────
    --    Eén tarief voor alles was te grof: rijden met de auto is iets
    --    anders dan een instellingsrit of een klus.
    --
    --    Het randgeval dat er echt toe doet: transport_mode is TEXT met een
    --    CHECK die vandaag alleen bike en car toestaat, maar migratie 003
    --    zegt met zoveel woorden dat die CHECK later verruimd wordt
    --    (scooter, bakfiets). Gebeurt dat zonder dat hier een tarief bij
    --    komt, dan mag er GEEN nul uitrollen — dan hoort de regel zichtbaar
    --    onvolledig te zijn.
    CASE r.shift_type
      WHEN 'regular' THEN
        CASE r.transport_mode
          WHEN 'bike' THEN v_hourly := v_rate.hourly_rate_bike; v_kind := 'fiets';
          WHEN 'car'  THEN v_hourly := v_rate.hourly_rate_car;  v_kind := 'auto';
          ELSE
            v_hourly := NULL;
            v_kind   := format('vervoermiddel %s', COALESCE(r.transport_mode, 'onbekend'));
        END CASE;
      WHEN 'institution'     THEN v_hourly := v_rate.hourly_rate_institution; v_kind := 'instelling';
      WHEN 'other_transport' THEN v_hourly := v_rate.hourly_rate_other;       v_kind := 'overig transport';
      ELSE v_hourly := NULL; v_kind := r.shift_type;
    END CASE;


    -- ── Reiskosten, naar rato ──────────────────────────────────────────
    v_travel := CASE
      WHEN r.claims_travel IS TRUE AND r.computed_reimbursable_km IS NOT NULL AND r.rate_per_km IS NOT NULL
      THEN round(r.computed_reimbursable_km * r.rate_per_km * v_share, 2)
      ELSE 0
    END;

    -- ── Onkosten, naar rato ────────────────────────────────────────────
    -- Doorbelasten zonder marge, op dezelfde verhouding als de uren. Geen
    -- onkosten is hier echt 0 en niet onbekend: een lege lijst betekent dat de
    -- koerier er geen had.
    v_expenses := round(COALESCE(r.expense_total, 0) * v_share, 2);

    -- ── De regel ───────────────────────────────────────────────────────
    -- Het gereserveerde blok van deze apotheek: wat er gepland stond, niet
    -- wat ervan gewerkt is. Bij een gesplitste keten betaalt de keten dit blok
    -- altijd; alles daarboven is meerwerk en gaat naar het filiaal.
    v_plan_min := COALESCE(r.budgeted_minutes, COALESCE(v_planned, 0) * v_share);

    shift_id              := r.id;
    shift_date            := r.shift_date;
    shift_type            := r.shift_type;
    courier_name          := r.courier_name;
    pharmacies_in_shift   := v_n;
    planned_minutes       := COALESCE(
                               r.budgeted_minutes,
                               CASE WHEN v_planned IS NULL THEN NULL
                                    ELSE round(v_planned * v_share)::INT END);
    share_pct             := round(v_share * 100, 1);
    shift_planned_minutes := v_planned;
    shift_actual_minutes  := v_actual;
    billed_minutes        := v_billed;
    from_declaration      := v_actual IS NOT NULL;
    extra_work_status     := r.extra_status;
    extra_work_minutes    := r.extra_share_minutes;
    chain_id              := v_chain.id;
    chain_name            := v_chain.name;
    split_active          := v_split;
    rate_id               := v_rate.id;
    urgent_note           := r.urgent_note;

    IF r.shift_type = 'urgent' THEN
      -- Spoed: alleen het afgesproken bedrag. De uren blijven als informatie in
      -- de regel staan, zodat zichtbaar is waar het bedrag tegenover staat.
      hourly_rate   := NULL;
      hours_amount  := NULL;
      start_amount  := NULL;
      travel_amount := NULL;
      -- Ook de onkosten niet: bij spoed telt alleen het afgesproken bedrag.
      expenses_amount := NULL;
      urgent_amount := r.urgent_amount;
      line_total    := r.urgent_amount;
      -- Spoed is per definitie geen onderdeel van het afgesproken pakket:
      -- het bedrag is telefonisch met het filiaal afgesproken en gaat daar
      -- ook heen.
      chain_amount  := 0;
      branch_amount := r.urgent_amount;

      -- De meldingen tot hier gaan allemaal over uren, en die raken het
      -- factuurbedrag bij spoed niet. Een markering op een regel die klopt leert
      -- de planner om markeringen te negeren.
      v_reasons := ARRAY[]::TEXT[];
      IF r.urgent_amount IS NULL THEN
        v_reasons := v_reasons || 'spoedbedrag nog niet ingevuld'::TEXT;
      END IF;
    ELSE
      IF v_rate.id IS NULL THEN
        v_reasons := v_reasons || format('geen tarief voor deze apotheek op %s', r.shift_date);
      ELSIF v_hourly IS NULL THEN
        -- Er is wél een tariefrij, maar geen bedrag voor dit soort werk. Dat is
        -- iets anders dan "geen tarief" en verdient dus een eigen melding.
        v_reasons := v_reasons || format('geen uurtarief voor %s op %s', v_kind, r.shift_date);
      END IF;

      hourly_rate   := v_hourly;
      -- start_rate blijft ongemoeid en wordt niet verdeeld: eigen opdracht. Bij
      -- BENU-filialen staat er 0 in, en dat is een waarde en geen uitzondering.
      start_amount  := v_rate.start_rate;
      -- Op v_capped, niet op v_billed: billed_minutes blijft tonen wat er
      -- werkelijk gewerkt is, ook als een deel nog niet gefactureerd wordt.
      hours_amount  := CASE WHEN v_hourly IS NULL OR v_capped IS NULL THEN NULL
                            ELSE round(v_capped / 60 * v_hourly, 2) END;
      travel_amount := v_travel;
      expenses_amount := v_expenses;
      urgent_amount := NULL;
      line_total    := CASE WHEN v_hourly IS NULL OR v_capped IS NULL THEN NULL
                            ELSE hours_amount + COALESCE(start_amount, 0)
                                 + COALESCE(v_travel, 0) + COALESCE(v_expenses, 0) END;

      -- De splitsing: het geplande deel plus het starttarief vormen samen het
      -- afgesproken pakket en gaan naar de keten. Alles wat daarvan afwijkt —
      -- goedgekeurd meerwerk, reiskosten, onkosten — gaat naar het filiaal dat
      -- het veroorzaakte. Staat de splitsing uit, dan gaat alles naar het
      -- filiaal en verandert er niets.
      IF v_split AND v_hourly IS NOT NULL AND v_capped IS NOT NULL THEN
        -- Model A: de keten betaalt het gereserveerde blok, ook als er korter
        -- gewerkt is. Het filiaal betaalt wat daarboven uitkomt — en dat is per
        -- definitie alleen het meerwerk dat is goedgekeurd of verlopen, want
        -- v_capped is hierboven al teruggebracht tot het geplande deel zolang de
        -- apotheek niet gereageerd heeft.
        v_chain_min  := COALESCE(v_plan_min, 0);
        v_branch_min := greatest(COALESCE(v_capped, 0) - v_chain_min, 0);

        chain_amount  := round(v_chain_min / 60 * v_hourly, 2) + COALESCE(start_amount, 0);
        branch_amount := round(v_branch_min / 60 * v_hourly, 2)
                         + COALESCE(v_travel, 0) + COALESCE(v_expenses, 0);

        -- Het regeltotaal wordt hier opnieuw bepaald: bij een korter gewerkte
        -- dienst rekent de keten het volle blok, en dan klopt het bedrag dat
        -- hierboven op werkelijke uren is berekend niet meer.
        hours_amount  := round(v_chain_min / 60 * v_hourly, 2)
                         + round(v_branch_min / 60 * v_hourly, 2);
        line_total    := chain_amount + branch_amount;
      ELSE
        chain_amount  := 0;
        branch_amount := line_total;
      END IF;

      -- Geen totaal → geen enkel bedrag. Anders telt zo'n regel wel mee in een
      -- subtotaal maar niet in het eindtotaal, en dan tellen de kolommen in het
      -- overzicht niet meer op tot de onderste regel.
      IF line_total IS NULL THEN
        hours_amount    := NULL;
        start_amount    := NULL;
        travel_amount   := NULL;
        expenses_amount := NULL;
        chain_amount    := NULL;
        branch_amount   := NULL;
      END IF;
    END IF;

    incomplete := array_length(v_reasons, 1) IS NOT NULL;
    reason     := CASE WHEN incomplete THEN array_to_string(v_reasons, '; ') END;
    RETURN NEXT;
  END LOOP;
END;
$$;

REVOKE ALL     ON FUNCTION public.invoice_lines(TEXT, DATE, DATE)           FROM PUBLIC, anon;
REVOKE ALL     ON FUNCTION public.pharmacy_chain(TEXT)                      FROM PUBLIC, anon, authenticated;
REVOKE ALL     ON FUNCTION public.set_group_billing(TEXT, TEXT, BOOLEAN)    FROM PUBLIC, anon;
REVOKE ALL     ON FUNCTION public.chain_overview()                          FROM PUBLIC, anon;

GRANT  EXECUTE ON FUNCTION public.invoice_lines(TEXT, DATE, DATE)           TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.pharmacy_chain(TEXT)                      TO service_role;
GRANT  EXECUTE ON FUNCTION public.set_group_billing(TEXT, TEXT, BOOLEAN)    TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.chain_overview()                          TO authenticated, service_role;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie
--   1. De drie ketens met hun instelling — alle drie horen nog op uit te staan.
--   2. Apotheken zonder keten. Die kunnen nooit gesplitst worden; hun regels
--      gaan altijd volledig naar het filiaal.
-- ────────────────────────────────────────────────────────────────────────
SELECT g.id, g.name, g.billing_email, g.split_extra_work,
       (SELECT count(*) FROM public.pharmacies p WHERE p."groupId" = g.id) AS apotheken
FROM public.groups g ORDER BY g.name;

SELECT id, name FROM public.pharmacies WHERE "groupId" IS NULL ORDER BY name;

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
