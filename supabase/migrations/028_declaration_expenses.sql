-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — onkosten bij de nadeclaratie — migratie 028
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 018 t/m 027 eerst.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien, en draai daarna       │
-- │ supabase/tests/028_declaration_expenses_test.sql.                      │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAT ER BIJ KOMT
--   Onkosten die géén kilometervergoeding zijn: parkeren, een veerpont, een
--   OV-kaartje. Meerdere per declaratie, met een omschrijving en een bedrag.
--
--   declaration_compute() wordt NIET aangeraakt. Die berekent de reiskostenregel
--   met haar vier takken, en onkosten staan daar los van: ze worden niet berekend
--   maar opgegeven, en er zit geen drempel, geen tarief en geen standplaats aan
--   vast. Ze horen dus niet in die rekenregel en ook niet in
--   computed_reimbursable_km — anders lopen "wat de regel oplevert" en "wat de
--   koerier voorschoot" door elkaar.
--
-- GEEN BESTANDSUPLOAD
--   Bonnetjes gaan buiten het systeem om, per mail. Deze tabel legt vast wát er
--   gedeclareerd is, niet waarmee het onderbouwd is.
--
-- ┌─ employmentType — ONBEVESTIGD VELD ────────────────────────────────────┐
-- │ De opdracht vraagt om een markering bij koeriers met een employmentType │
-- │ ongelijk aan 'zzp'. Dat veld komt in deze repo NERGENS voor: van        │
-- │ user_profiles zijn hier alleen id, name, role, pharmacy_ids en          │
-- │ home_pharmacy_id in gebruik. Het bestaat vermoedelijk wel in het schema │
-- │ van de bezorg-app (net als hourlyWage), maar naam, schrijfwijze en      │
-- │ waarden zijn hier niet vast te stellen.                                 │
-- │                                                                        │
-- │ Daarom leest declaration_expects_receipt() het veld via to_jsonb():     │
-- │ bestaat de kolom niet, dan levert dat NULL op in plaats van een functie │
-- │ die niet eens aangemaakt kan worden. Bij NULL of een lege waarde wordt  │
-- │ er GEEN bon verwacht — liever geen markering dan bij iedereen één, want │
-- │ een markering die altijd staat leest niemand meer.                      │
-- │                                                                        │
-- │ De verificatiequery onderaan laat zien welke waarden er werkelijk in    │
-- │ staan. Klopt 'zzp' niet, dan is dat één regel in die functie.           │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- DRIE FUNCTIES OPNIEUW NEERGEZET
--   declaration_by_token(), declaration_overview() en invoice_lines() krijgen er
--   kolommen bij, en CREATE OR REPLACE kan een returntype niet wijzigen. Hun body
--   is letterlijk overgenomen uit 023, 021 en 026, met alleen de nieuwe kolommen
--   erbij; de rechten staan onderaan weer, want die verdwijnen met een DROP.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────
-- 1. declaration_expenses — één rij per opgegeven post.
--    Bedrag strikt groter dan nul: een post van € 0,00 is geen onkost maar een
--    half ingevulde regel, en die hoort niet op een factuur te belanden.
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.declaration_expenses (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  declaration_id UUID NOT NULL REFERENCES public.shift_declarations(id) ON DELETE CASCADE,
  description    TEXT NOT NULL CHECK (btrim(description) <> ''),
  amount_eur     NUMERIC(8,2) NOT NULL CHECK (amount_eur > 0),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS declaration_expenses_declaration_idx
  ON public.declaration_expenses (declaration_id);

COMMENT ON TABLE public.declaration_expenses IS
  'Onkosten bij een dienst die geen kilometervergoeding zijn (migratie 028): '
  'parkeren, veerpont, OV. Opgegeven door de koerier op de invulpagina. Het '
  'bonnetje zit hier niet in — dat gaat per mail.';

-- Dicht, net als shift_declarations zelf: de invulpagina praat uitsluitend met
-- de Edge Function, en het plannerscherm leest via declaration_overview().
ALTER TABLE public.declaration_expenses ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.declaration_expenses FROM PUBLIC, anon, authenticated;


-- ────────────────────────────────────────────────────────────────────────
-- 2. declaration_expects_receipt — wordt er een bon verwacht van deze koerier?
--    Zie het kader bovenaan: het veld wordt via to_jsonb() gelezen zodat een
--    ontbrekende kolom hier geen fout oplevert maar NULL.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.declaration_expects_receipt(p_courier_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT COALESCE(
           lower(btrim(to_jsonb(up) ->> 'employmentType')) NOT IN ('zzp', ''),
           false)
  FROM public.user_profiles up
  WHERE up.id = p_courier_id;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 3. declaration_set_expenses — de koerier legt zijn posten vast.
--    Het token bepaalt de rij, net als bij declaration_submit(): er gaat geen
--    declaration_id over de lijn, dus een token is nooit om te buigen naar een
--    andere dienst. Dezelfde toegangsregels als indienen, inclusief de meldingen
--    uit migratie 022.
--
--    Vervangt alle posten in één keer. De invulpagina stuurt de hele lijst; per
--    regel bijhouden wat er gewijzigd is levert alleen toestand op die uit de
--    pas kan lopen.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.declaration_set_expenses(
  p_token TEXT, p_expenses JSONB
)
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_dec    public.shift_declarations;
  v_row    JSONB;
  v_desc   TEXT;
  v_amount NUMERIC;
  v_n      INT := 0;
BEGIN
  SELECT d.* INTO v_dec
  FROM public.shift_declarations d
  WHERE d.token_hash = public.declaration_hash_token(p_token);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Deze link is niet (meer) geldig.' USING ERRCODE = '28000';
  END IF;
  IF v_dec.status = 'approved' THEN
    RAISE EXCEPTION 'Deze declaratie is al goedgekeurd en kan niet meer worden aangepast.'
      USING ERRCODE = '45003';
  ELSIF v_dec.status = 'disputed' THEN
    RAISE EXCEPTION 'De planning kijkt hier nog naar. Neem contact op om iets te wijzigen.'
      USING ERRCODE = '45002';
  ELSIF v_dec.token_expires_at <= now() THEN
    RAISE EXCEPTION 'Deze link is verlopen. Neem contact op met de planning.'
      USING ERRCODE = '45001';
  END IF;

  DELETE FROM public.declaration_expenses WHERE declaration_id = v_dec.id;

  FOR v_row IN SELECT * FROM jsonb_array_elements(COALESCE(p_expenses, '[]'::jsonb))
  LOOP
    v_desc   := btrim(COALESCE(v_row ->> 'description', ''));
    v_amount := NULLIF(v_row ->> 'amount_eur', '')::NUMERIC;

    -- Een lege regel is geen fout: het formulier begint met één lege regel, en
    -- die hoort gewoon te verdwijnen als de koerier er niets in zet.
    CONTINUE WHEN v_desc = '' AND (v_amount IS NULL OR v_amount = 0);

    IF v_desc = '' THEN
      RAISE EXCEPTION 'Vul bij elke onkostenpost een omschrijving in.';
    END IF;
    IF v_amount IS NULL OR v_amount <= 0 THEN
      RAISE EXCEPTION 'Vul bij "%" een bedrag groter dan nul in.', v_desc;
    END IF;

    INSERT INTO public.declaration_expenses (declaration_id, description, amount_eur)
    VALUES (v_dec.id, left(v_desc, 200), round(v_amount, 2));
    v_n := v_n + 1;
  END LOOP;

  RETURN v_n;
END;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 4. declaration_by_token — de invulpagina krijgt de posten en de bon-vraag.
--    Body letterlijk uit migratie 023, met twee kolommen erbij.
-- ────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.declaration_by_token(TEXT);

CREATE FUNCTION public.declaration_by_token(p_token TEXT)
RETURNS TABLE (
  declaration_id    UUID,
  status            TEXT,
  courier_name      TEXT,
  shift_date        DATE,
  start_time        TEXT,
  budgeted_end_time TEXT,
  transport_mode    TEXT,
  own_car           BOOLEAN,
  pharmacies        JSONB,
  actual_start      TEXT,
  actual_end        TEXT,
  claims_travel     BOOLEAN,
  own_car_km        NUMERIC,
  courier_note      TEXT,
  submitted_at      TIMESTAMPTZ,
  -- Nieuw: waarom de planning betwist heeft. Bij een goedgekeurde declaratie
  -- meestal leeg; bij een betwiste is dit het enige wat de koerier verder helpt.
  review_note       TEXT,
  -- Onkosten die geen kilometervergoeding zijn (migratie 028), en of er een
  -- bon verwacht wordt. Dat laatste is een herinnering, geen voorwaarde.
  expenses          JSONB,
  expects_receipt   BOOLEAN
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT d.id, d.status, up.name,
         s.shift_date,
         to_char(s.start_time, 'HH24:MI'),
         to_char(s.budgeted_end_time, 'HH24:MI'),
         s.transport_mode,
         s.transport_mode = 'car' AND s.car_is_own IS TRUE,
         (SELECT COALESCE(jsonb_agg(p.name ORDER BY p.name), '[]'::jsonb)
          FROM public.shift_pharmacies sp
          JOIN public.pharmacies p ON p.id = sp.pharmacy_id
          WHERE sp.shift_id = s.id),
         to_char(d.actual_start, 'HH24:MI'),
         to_char(d.actual_end,   'HH24:MI'),
         d.claims_travel, d.own_car_km, d.courier_note, d.submitted_at,
         d.review_note,
         (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                     'description', e.description, 'amount_eur', e.amount_eur)
                     ORDER BY e.created_at), '[]'::jsonb)
            FROM public.declaration_expenses e WHERE e.declaration_id = d.id),
         public.declaration_expects_receipt(d.courier_id)
  FROM public.shift_declarations d
  JOIN public.shifts s         ON s.id  = d.shift_id
  JOIN public.user_profiles up ON up.id = d.courier_id
  WHERE d.token_hash = public.declaration_hash_token(p_token)
    AND d.token_expires_at > now();
  -- Geen statusfilter meer. Wat er met de rij gedaan mag worden is een vraag voor
  -- declaration_submit(); wat er getoond mag worden is deze. Die twee liepen door
  -- elkaar en dat maakte "al beoordeeld" niet te onderscheiden van "kapotte link".
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 5. declaration_overview — de plannerkant.
--    Body letterlijk uit migratie 021, met drie kolommen erbij.
-- ────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.declaration_overview(DATE, DATE);

CREATE FUNCTION public.declaration_overview(
  p_from DATE DEFAULT NULL, p_to DATE DEFAULT NULL
)
RETURNS TABLE (
  declaration_id      UUID,
  shift_id            UUID,
  status              TEXT,
  courier_id          UUID,
  courier_name        TEXT,
  shift_date          DATE,
  pharmacies          JSONB,
  transport_mode      TEXT,
  own_car             BOOLEAN,
  planned_start       TEXT,
  planned_end         TEXT,
  planned_minutes     INT,
  actual_start        TEXT,
  actual_end          TEXT,
  actual_minutes      INT,
  claims_travel       BOOLEAN,
  own_car_km          NUMERIC,
  courier_note        TEXT,
  computed_distance_km     NUMERIC,
  computed_reimbursable_km NUMERIC,
  computed_rule            TEXT,
  computed_pharmacy_name   TEXT,
  computed_incomplete      BOOLEAN,
  computed_reason          TEXT,
  rate_per_km         NUMERIC,
  threshold_km        NUMERIC,
  amount_eur          NUMERIC,
  submitted_at        TIMESTAMPTZ,
  hours_after_end       NUMERIC,
  submitted_in_time     BOOLEAN,
  expected_within_hours INT,
  reviewed_at         TIMESTAMPTZ,
  reviewer_name       TEXT,
  review_note         TEXT,
  -- Onkosten (migratie 028): de regels zelf, het totaal, en of er nog een bon
  -- verwacht wordt van deze koerier.
  expenses            JSONB,
  expenses_amount     NUMERIC,
  expects_receipt     BOOLEAN
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT
    d.id, d.shift_id, d.status, d.courier_id, up.name,
    s.shift_date,
    (SELECT COALESCE(jsonb_agg(p.name ORDER BY p.name), '[]'::jsonb)
     FROM public.shift_pharmacies sp
     JOIN public.pharmacies p ON p.id = sp.pharmacy_id
     WHERE sp.shift_id = s.id),
    s.transport_mode,
    s.transport_mode = 'car' AND s.car_is_own IS TRUE,
    to_char(s.start_time, 'HH24:MI'),
    to_char(s.budgeted_end_time, 'HH24:MI'),
    -- Geplande en werkelijke duur in minuten. Een eindtijd die vóór de starttijd
    -- ligt loopt over middernacht heen en krijgt er een etmaal bij.
    CASE WHEN s.budgeted_end_time IS NULL THEN NULL ELSE
      (EXTRACT(EPOCH FROM (s.budgeted_end_time - s.start_time
        + CASE WHEN s.budgeted_end_time <= s.start_time THEN INTERVAL '1 day' ELSE INTERVAL '0' END)) / 60)::INT
    END,
    to_char(d.actual_start, 'HH24:MI'),
    to_char(d.actual_end,   'HH24:MI'),
    CASE WHEN d.actual_start IS NULL OR d.actual_end IS NULL THEN NULL ELSE
      (EXTRACT(EPOCH FROM (d.actual_end - d.actual_start
        + CASE WHEN d.actual_end <= d.actual_start THEN INTERVAL '1 day' ELSE INTERVAL '0' END)) / 60)::INT
    END,
    d.claims_travel, d.own_car_km, d.courier_note,
    d.computed_distance_km, d.computed_reimbursable_km, d.computed_rule,
    (SELECT p.name FROM public.pharmacies p WHERE p.id = d.computed_pharmacy_id),
    d.computed_incomplete, d.computed_reason,
    r.rate_per_km, r.threshold_km,
    round(d.computed_reimbursable_km * r.rate_per_km, 2),
    d.submitted_at,
    -- Ingediend: hoe lang na afloop. Nog niet ingediend: hoe lang hij al open
    -- staat. Op één decimaal; preciezer dan dat zegt niets over een termijn in
    -- dagen, en een tabel leest niet fijner van meer cijfers.
    round((EXTRACT(EPOCH FROM (
      COALESCE(d.submitted_at, now())
      - public.declaration_shift_end(s.shift_date, s.start_time, s.budgeted_end_time)
    )) / 3600)::NUMERIC, 1),
    -- NULL zolang er niets is ingediend: dan is er niets om binnen of buiten de
    -- termijn te noemen.
    CASE WHEN d.submitted_at IS NULL THEN NULL ELSE
      d.submitted_at <= public.declaration_shift_end(s.shift_date, s.start_time, s.budgeted_end_time)
                        + make_interval(hours => c.expected_within_hours)
    END,
    c.expected_within_hours,
    d.reviewed_at,
    (SELECT rp.name FROM public.user_profiles rp WHERE rp.id = d.reviewed_by),
    d.review_note,
    (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                     'description', e.description, 'amount_eur', e.amount_eur)
                     ORDER BY e.created_at), '[]'::jsonb)
            FROM public.declaration_expenses e WHERE e.declaration_id = d.id),
    (SELECT COALESCE(sum(e.amount_eur), 0) FROM public.declaration_expenses e
      WHERE e.declaration_id = d.id),
    -- 'Bon verwacht' alleen als er ook werkelijk onkosten zijn: een
    -- herinnering bij een lege declaratie is ruis.
    public.declaration_expects_receipt(d.courier_id)
      AND EXISTS (SELECT 1 FROM public.declaration_expenses e WHERE e.declaration_id = d.id)
  FROM public.shift_declarations d
  JOIN public.shifts s         ON s.id  = d.shift_id
  JOIN public.user_profiles up ON up.id = d.courier_id
  LEFT JOIN public.reimbursement_rates r ON r.id = d.rate_id
  CROSS JOIN public.declaration_settings c
  WHERE public.is_privileged()
    AND (p_from IS NULL OR s.shift_date >= p_from)
    AND (p_to   IS NULL OR s.shift_date <= p_to)
  ORDER BY s.shift_date DESC, s.start_time DESC;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 6. invoice_lines — onkosten doorbelasten, zonder marge.
--    Body letterlijk uit migratie 026, met de onkostenkolom erbij. Naar rato van
--    de geplande minuten, net als de uren en de reiskosten: bij een gedeelde
--    dienst is een parkeerkaartje niet aan één apotheek toe te schrijven.
--    Zonder marge — dit is doorbelasten, geen dienst.
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
  v_dev      NUMERIC;
BEGIN
  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'Alleen planners mogen factuurregels opvragen.';
  END IF;

  SELECT * INTO v_cfg FROM public.invoice_settings WHERE id;

  FOR r IN
    SELECT s.id, s.shift_date, s.shift_type, s.start_time, s.budgeted_end_time,
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
             WHERE e.declaration_id = d.id) AS expense_total
    FROM public.shift_pharmacies sp
    JOIN public.shifts s              ON s.id = sp.shift_id
    LEFT JOIN public.user_profiles up ON up.id = s.courier_id
    LEFT JOIN public.shift_declarations d ON d.shift_id = s.id
    LEFT JOIN public.reimbursement_rates rr ON rr.id = d.rate_id
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

    -- ── Tarief ─────────────────────────────────────────────────────────
    v_rate := public.pharmacy_rate_on(p_pharmacy_id, r.shift_date);

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
      END IF;

      hourly_rate   := v_rate.hourly_rate;
      start_amount  := v_rate.start_rate;   -- niet verdelen: eigen opdracht
      hours_amount  := CASE WHEN v_rate.id IS NULL OR v_billed IS NULL THEN NULL
                            ELSE round(v_billed / 60 * v_rate.hourly_rate, 2) END;
      travel_amount := v_travel;
      expenses_amount := v_expenses;
      urgent_amount := NULL;
      line_total    := CASE WHEN v_rate.id IS NULL OR v_billed IS NULL THEN NULL
                            ELSE hours_amount + COALESCE(start_amount, 0)
                                 + COALESCE(v_travel, 0) + COALESCE(v_expenses, 0) END;

      -- Geen totaal → geen enkel bedrag. Anders telt zo'n regel wel mee in een
      -- subtotaal maar niet in het eindtotaal, en dan tellen de kolommen in het
      -- overzicht niet meer op tot de onderste regel.
      IF line_total IS NULL THEN
        hours_amount    := NULL;
        start_amount    := NULL;
        travel_amount   := NULL;
        expenses_amount := NULL;
      END IF;
    END IF;

    incomplete := array_length(v_reasons, 1) IS NOT NULL;
    reason     := CASE WHEN incomplete THEN array_to_string(v_reasons, '; ') END;
    RETURN NEXT;
  END LOOP;
END;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 7. Rechten. De DROP's hierboven namen de bestaande ACL mee, dus die staat hier
--    opnieuw — gelijk aan wat 019/021/023/025 hadden.
-- ────────────────────────────────────────────────────────────────────────
REVOKE ALL     ON FUNCTION public.declaration_by_token(TEXT)            FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.declaration_by_token(TEXT)            TO service_role;

REVOKE ALL     ON FUNCTION public.declaration_set_expenses(TEXT, JSONB) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.declaration_set_expenses(TEXT, JSONB) TO service_role;

REVOKE ALL     ON FUNCTION public.declaration_expects_receipt(UUID)     FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.declaration_expects_receipt(UUID)     TO authenticated, service_role;

REVOKE ALL     ON FUNCTION public.declaration_overview(DATE, DATE)      FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.declaration_overview(DATE, DATE)      TO authenticated, service_role;

REVOKE ALL     ON FUNCTION public.invoice_lines(TEXT, DATE, DATE)       FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.invoice_lines(TEXT, DATE, DATE)       TO authenticated, service_role;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie
--   1. De tabel staat er.
--   2. WELKE WAARDEN STAAN ER IN employmentType? Dit is de reden om deze query
--      te draaien: komt er niets uit, dan bestaat de kolom niet (of is hij leeg)
--      en wordt er nergens een bon verwacht. Staat er iets anders dan 'zzp' voor
--      de zelfstandigen, dan moet die ene vergelijking in
--      declaration_expects_receipt() worden aangepast.
-- ────────────────────────────────────────────────────────────────────────
SELECT count(*) AS onkostenposten FROM public.declaration_expenses;

SELECT to_jsonb(up) ->> 'employmentType' AS employment_type,
       count(*) AS koeriers,
       bool_or(public.declaration_expects_receipt(up.id)) AS bon_verwacht
FROM public.user_profiles up
WHERE up.role = 'courier'
GROUP BY 1
ORDER BY 1;

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
