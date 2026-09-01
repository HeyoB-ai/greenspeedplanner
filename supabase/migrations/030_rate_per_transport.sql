-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — uurtarief per soort werk — migratie 030
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 025 t/m 029 eerst.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien, en draai daarna       │
-- │ supabase/tests/030_rate_per_transport_test.sql.                        │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAT ER VERANDERT
--   pharmacy_rates had één hourly_rate. Dat is te grof: wat het werk kost hangt
--   af van wát het is.
--
--     regular          → hourly_rate_bike of hourly_rate_car, op transport_mode
--     institution      → hourly_rate_institution
--     other_transport  → hourly_rate_other  (klussen: verhuizen, auto wegbrengen)
--     urgent (spoed)   → het vrije bedrag in shifts.urgent_amount, ongewijzigd
--
--   start_rate blijft precies zoals hij was en wordt niet verdeeld. Bij
--   BENU-filialen staat daar 0 in; dat is een WAARDE en geen uitzondering in
--   code, en zo hoort het te blijven.
--
-- ┌─ HET RANDGEVAL DAT ERTOE DOET ─────────────────────────────────────────┐
-- │ transport_mode is TEXT met een CHECK die vandaag alleen bike en car    │
-- │ toestaat — maar migratie 003 zegt met zoveel woorden dat die CHECK      │
-- │ later verruimd wordt (scooter, bakfiets). Komt er dan een waarde bij    │
-- │ zonder tarief, dan mag er geen nul uitrollen: de factuurregel wordt     │
-- │ incomplete met een leesbare reden, in lijn met declaration_compute().   │
-- │ Hetzelfde geldt voor een tariefrij waarin dit ene veld leeg is.         │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- OVER DE VERVANGING VAN hourly_rate
--   De bestaande waarde wordt naar alle vier de nieuwe kolommen gekopieerd
--   voordat de oude verdwijnt. Daarmee rekent elke bestaande tariefrij precies
--   zoals gisteren, en is de aanpassing per soort werk een bewuste handeling in
--   het beheerscherm in plaats van iets wat stilzwijgend op nul valt.
--
--   Er staat een telling vooraf. Zijn het er meer dan een handvol, dan is de
--   aanname "nog leeg op wat testtarieven na" niet waar en stopt de migratie —
--   dan wil je eerst kijken wat er staat.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────
-- 1. Controle vooraf.
-- ────────────────────────────────────────────────────────────────────────
DO $$
DECLARE v_n INT;
BEGIN
  SELECT count(*) INTO v_n FROM public.pharmacy_rates;
  RAISE NOTICE 'pharmacy_rates bevat % rij(en) vóór deze migratie.', v_n;
  IF v_n > 25 THEN
    RAISE EXCEPTION
      'Er staan % tariefrijen in pharmacy_rates, meer dan de handvol testtarieven waar deze migratie van uitgaat. Kijk eerst wat er staat en pas zo nodig de kopieerstap hieronder aan.', v_n;
  END IF;
END $$;


-- ────────────────────────────────────────────────────────────────────────
-- 2. De vier nieuwe kolommen.
--    Nullable: een apotheek waar nooit een instellingsrit rijdt hoeft daar geen
--    tarief voor te hebben. Ontbreekt het tarief tóch bij een dienst van dat
--    soort, dan zegt de factuurregel dat.
-- ────────────────────────────────────────────────────────────────────────
ALTER TABLE public.pharmacy_rates
  ADD COLUMN IF NOT EXISTS hourly_rate_bike        NUMERIC(8,2),
  ADD COLUMN IF NOT EXISTS hourly_rate_car         NUMERIC(8,2),
  ADD COLUMN IF NOT EXISTS hourly_rate_institution NUMERIC(8,2),
  ADD COLUMN IF NOT EXISTS hourly_rate_other       NUMERIC(8,2);

DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT conname FROM pg_constraint
    WHERE conrelid = 'public.pharmacy_rates'::regclass AND contype = 'c'
      AND pg_get_constraintdef(oid) LIKE '%hourly_rate_%'
  LOOP
    EXECUTE format('ALTER TABLE public.pharmacy_rates DROP CONSTRAINT %I', r.conname);
  END LOOP;
END $$;

ALTER TABLE public.pharmacy_rates
  ADD CONSTRAINT pharmacy_rates_hourly_rates_chk CHECK (
        (hourly_rate_bike        IS NULL OR hourly_rate_bike        >= 0)
    AND (hourly_rate_car         IS NULL OR hourly_rate_car         >= 0)
    AND (hourly_rate_institution IS NULL OR hourly_rate_institution >= 0)
    AND (hourly_rate_other       IS NULL OR hourly_rate_other       >= 0));


-- ────────────────────────────────────────────────────────────────────────
-- 3. De bestaande waarde overnemen en de oude kolom opruimen.
--    Alleen waar het nieuwe veld nog leeg is, zodat deze migratie herhaalbaar
--    blijft en een al ingevuld tarief niet terugvalt op de oude waarde.
-- ────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'pharmacy_rates'
      AND column_name = 'hourly_rate'
  ) THEN
    EXECUTE $sql$
      UPDATE public.pharmacy_rates SET
        hourly_rate_bike        = COALESCE(hourly_rate_bike,        hourly_rate),
        hourly_rate_car         = COALESCE(hourly_rate_car,         hourly_rate),
        hourly_rate_institution = COALESCE(hourly_rate_institution, hourly_rate),
        hourly_rate_other       = COALESCE(hourly_rate_other,       hourly_rate)
    $sql$;
    EXECUTE 'ALTER TABLE public.pharmacy_rates DROP COLUMN hourly_rate';
    RAISE NOTICE 'hourly_rate gekopieerd naar de vier nieuwe kolommen en verwijderd.';
  ELSE
    RAISE NOTICE 'hourly_rate bestond al niet meer; niets te kopiëren.';
  END IF;
END $$;

COMMENT ON COLUMN public.pharmacy_rates.start_rate IS
  'Starttarief per opdracht, niet verdeeld over apotheken. Bij BENU-filialen 0 — '
  'dat is een waarde, geen uitzondering in code.';


-- ────────────────────────────────────────────────────────────────────────
-- 4. set_pharmacy_rate — vier tarieven in plaats van één.
--    Nieuwe signatuur, dus de oude eerst weg: anders staat er straks een
--    overload met vijf parameters naast een met acht en kiest PostgREST er zelf
--    een.
-- ────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.set_pharmacy_rate(TEXT, NUMERIC, NUMERIC, DATE, TEXT);

CREATE OR REPLACE FUNCTION public.set_pharmacy_rate(
  p_pharmacy_id TEXT,
  p_bike        NUMERIC,
  p_car         NUMERIC,
  p_institution NUMERIC,
  p_other       NUMERIC,
  p_start_rate  NUMERIC,
  p_effective_from DATE,
  p_note        TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_id UUID;
BEGIN
  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'Alleen planners mogen tarieven zetten.';
  END IF;

  INSERT INTO public.pharmacy_rates (
    pharmacy_id, hourly_rate_bike, hourly_rate_car, hourly_rate_institution,
    hourly_rate_other, start_rate, effective_from, note)
  VALUES (
    p_pharmacy_id, p_bike, p_car, p_institution, p_other,
    COALESCE(p_start_rate, 0), p_effective_from,
    NULLIF(btrim(COALESCE(p_note, '')), ''))
  ON CONFLICT (pharmacy_id, effective_from) DO UPDATE
    SET hourly_rate_bike        = EXCLUDED.hourly_rate_bike,
        hourly_rate_car         = EXCLUDED.hourly_rate_car,
        hourly_rate_institution = EXCLUDED.hourly_rate_institution,
        hourly_rate_other       = EXCLUDED.hourly_rate_other,
        start_rate              = EXCLUDED.start_rate,
        note                    = EXCLUDED.note
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$fn$;

REVOKE ALL     ON FUNCTION public.set_pharmacy_rate(TEXT, NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC, DATE, TEXT) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.set_pharmacy_rate(TEXT, NUMERIC, NUMERIC, NUMERIC, NUMERIC, NUMERIC, DATE, TEXT) TO authenticated, service_role;


-- ────────────────────────────────────────────────────────────────────────
-- 5. invoice_lines — het tarief kiezen op soort werk.
--    Body letterlijk uit migratie 028, met alleen de tariefkeuze erin. De
--    verdeelregels, de onkosten en de markeringen blijven zoals ze waren.
--    Returntype ongewijzigd, dus CREATE OR REPLACE volstaat.
-- ────────────────────────────────────────────────────────────────────────
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
  -- Het uurtarief dat bij DEZE dienst hoort. Sinds migratie 030 hangt dat
  -- van het diensttype af, en bij een reguliere dienst van het vervoermiddel.
  v_hourly   NUMERIC;
  v_kind     TEXT;    -- waar het tarief vandaan kwam, voor de melding

  v_dev      NUMERIC;
BEGIN
  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'Alleen planners mogen factuurregels opvragen.';
  END IF;

  SELECT * INTO v_cfg FROM public.invoice_settings WHERE id;

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
      ELSIF v_hourly IS NULL THEN
        -- Er is wél een tariefrij, maar geen bedrag voor dit soort werk. Dat is
        -- iets anders dan "geen tarief" en verdient dus een eigen melding.
        v_reasons := v_reasons || format('geen uurtarief voor %s op %s', v_kind, r.shift_date);
      END IF;

      hourly_rate   := v_hourly;
      -- start_rate blijft ongemoeid en wordt niet verdeeld: eigen opdracht. Bij
      -- BENU-filialen staat er 0 in, en dat is een waarde en geen uitzondering.
      start_amount  := v_rate.start_rate;
      hours_amount  := CASE WHEN v_hourly IS NULL OR v_billed IS NULL THEN NULL
                            ELSE round(v_billed / 60 * v_hourly, 2) END;
      travel_amount := v_travel;
      expenses_amount := v_expenses;
      urgent_amount := NULL;
      line_total    := CASE WHEN v_hourly IS NULL OR v_billed IS NULL THEN NULL
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

REVOKE ALL     ON FUNCTION public.invoice_lines(TEXT, DATE, DATE) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.invoice_lines(TEXT, DATE, DATE) TO authenticated, service_role;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie
--   1. De vier kolommen staan er en hourly_rate is weg.
--   2. Welke tariefrijen missen een bedrag voor een soort werk. Dat is geen
--      fout — een apotheek zonder instellingsritten hoeft dat tarief niet — maar
--      het is wel de lijst die verklaart waarom een factuurregel straks
--      onvolledig is.
-- ────────────────────────────────────────────────────────────────────────
SELECT string_agg(column_name, ', ' ORDER BY column_name) AS tariefkolommen
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'pharmacy_rates'
  AND column_name LIKE 'hourly_rate%';

SELECT p.name, r.effective_from,
       r.hourly_rate_bike, r.hourly_rate_car,
       r.hourly_rate_institution, r.hourly_rate_other, r.start_rate
FROM public.pharmacy_rates r
JOIN public.pharmacies p ON p.id = r.pharmacy_id
WHERE r.hourly_rate_bike IS NULL OR r.hourly_rate_car IS NULL
   OR r.hourly_rate_institution IS NULL OR r.hourly_rate_other IS NULL
ORDER BY p.name, r.effective_from DESC;

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
