-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — nadeclaratie: op tijd ingediend of niet — migratie 021
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 018 t/m 020 eerst.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien, en draai daarna       │
-- │ supabase/tests/021_declaration_timeliness_test.sql.                    │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAT ER BIJ KOMT
--   De planner wil zien of een koerier binnen 48 uur na afloop van zijn dienst
--   heeft ingediend. Dat is een VERWACHTING, geen harde grens: de link blijft
--   gewoon werken en token_valid_days blijft 30. Er is dus ook geen nieuwe
--   status en geen nieuwe kolom op shift_declarations — het is af te leiden uit
--   submitted_at en de eindtijd van de dienst, en dat blijft zo.
--
--   Wel een instelling, want 48 uur is een afspraak en geen natuurwet:
--   declaration_settings.expected_within_hours.
--
-- WAAROM declaration_overview OPNIEUW WORDT NEERGEZET IN PLAATS VAN VERVANGEN
--   CREATE OR REPLACE kan het returntype van een functie niet wijzigen, en er
--   komen drie kolommen bij. Daarom eerst DROP en dan CREATE — en daarna de
--   rechten opnieuw, want die verdwijnen met de functie. Dat kan hier veilig:
--   de functie wordt alleen door het plannerscherm aangeroepen, en dit bestand
--   draait in één transactie.
--
--   declaration_compute() blijft ONGEMOEID; die is in 020 gewijzigd en getest.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────
-- 1. De termijn als instelling.
--    Los van token_valid_days: dat is tot wanneer de link wérkt (30 dagen),
--    dit is binnen hoeveel uur we het gráág hebben (48). Die twee moeten uit
--    elkaar te houden zijn, anders wordt de verwachting stilzwijgend een grens.
-- ────────────────────────────────────────────────────────────────────────
ALTER TABLE public.declaration_settings
  ADD COLUMN IF NOT EXISTS expected_within_hours INT NOT NULL DEFAULT 48;

ALTER TABLE public.declaration_settings
  DROP CONSTRAINT IF EXISTS declaration_settings_expected_within_hours_check;

ALTER TABLE public.declaration_settings
  ADD CONSTRAINT declaration_settings_expected_within_hours_check
  CHECK (expected_within_hours > 0);

COMMENT ON COLUMN public.declaration_settings.expected_within_hours IS
  'Binnen hoeveel uur na afloop van de dienst we de opgave graag hebben. Een '
  'verwachting, geen grens: de invullink blijft werken tot token_valid_days.';


-- ────────────────────────────────────────────────────────────────────────
-- 2. declaration_expected_hours — de termijn voor de mail en de invulpagina.
--    Eén klein leespad, zodat de tekst in de mail en op de pagina de instelling
--    volgt in plaats van een getal dat in twee codebases herhaald staat.
--    De verzender en de invulpagina draaien allebei als service-role.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.declaration_expected_hours()
RETURNS INT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT expected_within_hours FROM public.declaration_settings WHERE id;
$$;

REVOKE ALL     ON FUNCTION public.declaration_expected_hours() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.declaration_expected_hours() TO service_role;


-- ────────────────────────────────────────────────────────────────────────
-- 3. declaration_overview — drie kolommen erbij.
--
--    hours_after_end   ingediend  → uren tussen de eindtijd van de dienst en
--                                   submitted_at
--                      nog niet   → uren sinds de eindtijd, dus hoe lang de rij
--                                   al openstaat
--    submitted_in_time ingediend  → viel dat binnen expected_within_hours
--                      nog niet   → NULL. Een rij die nog niet is ingediend is
--                                   niet "te laat"; hij is niet ingediend. Het
--                                   getal ernaast zegt hoe lang al.
--    expected_within_hours        de termijn zelf, zodat het scherm hem niet
--                                 hoeft te kennen — zelfde reden als waarom
--                                 tarief en drempel meekomen.
--
--    De eindtijd komt uit declaration_shift_end() (migratie 019), dezelfde
--    definitie waarmee de sweep bepaalt dat een dienst af is. Anders zou "48 uur
--    na afloop" hier iets anders betekenen dan daar.
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
  review_note         TEXT
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
    d.review_note
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

-- De rechten zijn met de oude functie verdwenen; hier staan ze weer.
REVOKE ALL     ON FUNCTION public.declaration_overview(DATE, DATE) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.declaration_overview(DATE, DATE) TO authenticated, service_role;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie — de instelling staat er, en de drie nieuwe kolommen zitten in de
-- functie.
--
-- De tweede query rekent bewust rechtstreeks op de tabellen en niet via
-- declaration_overview(): die functie filtert op is_privileged(), en in de SQL
-- Editor draai je als postgres zonder auth.uid(). Daar zou hij dus altijd nul
-- rijen geven, en dat leest als "er is niets" terwijl het "jij bent geen
-- planner" betekent.
-- ────────────────────────────────────────────────────────────────────────
SELECT active_from, max_age_days, token_valid_days, expected_within_hours
FROM public.declaration_settings;

SELECT pg_get_function_result(p.oid) LIKE '%submitted_in_time%'    AS heeft_op_tijd,
       pg_get_function_result(p.oid) LIKE '%hours_after_end%'      AS heeft_uren,
       pg_get_function_result(p.oid) LIKE '%expected_within_hours%' AS heeft_termijn
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'declaration_overview';

SELECT d.status,
       count(*)                                                        AS declaraties,
       count(*) FILTER (WHERE d.submitted_at IS NOT NULL
         AND d.submitted_at <= public.declaration_shift_end(s.shift_date, s.start_time, s.budgeted_end_time)
                              + make_interval(hours => c.expected_within_hours)) AS op_tijd,
       count(*) FILTER (WHERE d.submitted_at IS NOT NULL
         AND d.submitted_at >  public.declaration_shift_end(s.shift_date, s.start_time, s.budgeted_end_time)
                              + make_interval(hours => c.expected_within_hours)) AS te_laat
FROM public.shift_declarations d
JOIN public.shifts s ON s.id = d.shift_id
CROSS JOIN public.declaration_settings c
GROUP BY d.status
ORDER BY d.status;

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
