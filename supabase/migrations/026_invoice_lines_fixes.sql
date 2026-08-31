-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — invoice_lines: reden-opbouw en lege duur — 026
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 025 eerst. Deze migratie vervangt alleen de body van
-- invoice_lines(); signatuur en returntype blijven gelijk.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien, en draai daarna       │
-- │ supabase/tests/026_invoice_lines_fixes_test.sql.                       │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- ┌─ 1. "malformed array literal" — waar het vandaan komt ─────────────────┐
-- │ Er wordt in 025 nergens een losse tekst aan v_reasons toegewezen; élke │
-- │ regel is `v_reasons := v_reasons || …`. Dat is niet de fout.           │
-- │                                                                        │
-- │ De fout zit in de OPERATORKEUZE. Voor `text[] || <letterlijke tekst>`  │
-- │ heeft Postgres twee kandidaten:                                        │
-- │                                                                        │
-- │     anyarray || anyelement   → array met een element erbij             │
-- │     anyarray || anyarray     → twee arrays aan elkaar                  │
-- │                                                                        │
-- │ Een letterlijke 'tekst' heeft type `unknown`, en die past op beide. Bij │
-- │ de tweede vorm wordt de tekst gelezen als ARRAY-literaal, en daar hoort │
-- │ {…} bij — vandaar "malformed array literal", op de uitvoering en niet   │
-- │ bij het aanmaken van de functie.                                       │
-- │                                                                        │
-- │ De regels met format(…) hadden er geen last van: format() geeft een    │
-- │ getypeerde text terug, en dan is er niets meer te kiezen. Precies       │
-- │ daarom viel dit pas op bij de takken met een vaste zin.                │
-- │                                                                        │
-- │ Oplossing: de tekst expliciet typeren met ::TEXT. Dan valt de          │
-- │ array-vorm af en blijft er één kandidaat over.                         │
-- │                                                                        │
-- │ ⚠ DEZELFDE CONSTRUCTIE STAAT IN declaration_compute() (migratie 020,   │
-- │   regels 102, 145 en 161) en in 018. Die functie is niet aangeraakt —   │
-- │   dat was de opdracht — maar loopt op dezelfde fout zodra een van die   │
-- │   drie takken zich voordoet: een koerier zonder standplaats, een        │
-- │   onbekende afstand, of een dienst zonder apotheek. Zie de README.      │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- ┌─ 2. Geen werkelijke duur én geen geplande eindtijd ────────────────────┐
-- │ Dat geval dekte het ontwerp niet. Er viel niets te factureren, en de    │
-- │ regel rekende met nul minuten: 0 uren plus een volledig starttarief,    │
-- │ met een totaal dat er gewoon uitzag. Stilzwijgend te weinig factureren  │
-- │ is precies wat de markeringen elders moeten voorkomen.                  │
-- │                                                                        │
-- │ Voortaan: de regel verschijnt WEL in het overzicht — hij mag niet       │
-- │ wegvallen, want dan mist de planner de dienst helemaal — maar zonder    │
-- │ bedragen en met de markering erbij.                                     │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- ┌─ 3. Geen totaal betekent geen bedragen ────────────────────────────────┐
-- │ Bijvangst van punt 2. Een regel zonder line_total (geen tarief, of geen │
-- │ duur) hield wel losse bedragen: bij een ontbrekend tarief stond er nog  │
-- │ een reiskostenbedrag. Het overzicht telt zo'n regel niet mee in het     │
-- │ eindtotaal maar wél in dat subtotaal, en dan tellen de kolommen niet    │
-- │ meer op tot de onderste regel. Nu geldt: geen totaal → geen enkel       │
-- │ bedrag. De regel is dan puur een signaal.                               │
-- └────────────────────────────────────────────────────────────────────────┘
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

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
           d.computed_reimbursable_km, rr.rate_per_km
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
      urgent_amount := NULL;
      line_total    := CASE WHEN v_rate.id IS NULL OR v_billed IS NULL THEN NULL
                            ELSE hours_amount + COALESCE(start_amount, 0) + COALESCE(v_travel, 0) END;

      -- Geen totaal → geen enkel bedrag. Anders telt zo'n regel wel mee in een
      -- subtotaal maar niet in het eindtotaal, en dan tellen de kolommen in het
      -- overzicht niet meer op tot de onderste regel.
      IF line_total IS NULL THEN
        hours_amount  := NULL;
        start_amount  := NULL;
        travel_amount := NULL;
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
-- Verificatie — de operatorkeuze, los van deze functie. De eerste vorm is wat
-- er nu overal staat en hoort te werken; de tweede is de constructie die de
-- fout gaf. Beide moeten hier één rij met één element opleveren, en de tweede
-- valt dus om zolang Postgres hem als array leest.
-- ────────────────────────────────────────────────────────────────────────
SELECT array_length(ARRAY[]::TEXT[] || 'een reden'::TEXT, 1) AS met_cast_werkt;

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
