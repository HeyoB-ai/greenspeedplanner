-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — de PDA-tijd als eigen gegeven — 053
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor. Draai 051 en 052 eerst.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien.                       │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- ER ZIJN DRIE TIJDEN, GEEN TWEE
--   Tot nu toe kende een declaratie er twee: wat er begroot was, en wat de
--   koerier werkelijk reed. Bij een BENU selfbilling-dienst is er een derde, en
--   die is de belangrijkste van de drie:
--
--     PDA-tijd      wat de PDA van de apotheek aangeeft. De koerier ziet hem bij
--                   aanvang van zijn dienst en onthoudt hem. Dít is de tijd die
--                   BENU vergoedt.
--     geplande tijd wat de planning had bedacht. Referentie, verder niets.
--     werkelijke    wat de koerier werkelijk gereden heeft. Hierop wordt hij
--                   tijd          uitbetaald.
--
--   De drempel liep tot nu toe tegen de GEPLANDE tijd. Dat is voor een
--   BENU-dienst de verkeerde maatstaf: wat doorbelast mag worden is de tijd
--   bovenop wat BENU al vergoedt, en dat is de PDA-tijd. Liep de planning er
--   zelf naast, dan is dat geen uitloop die een apotheek hoort te betalen.
--
-- ÉÉN REFERENTIE, TWEE GEBRUIKERS
--   declaration_submit() bepaalt of er een verklaring nodig is, en
--   extra_work_sweep() of er een goedkeuringsverzoek uitgaat. Die twee MOETEN
--   dezelfde maatstaf hanteren — anders vraagt het formulier om een verklaring
--   die de facturatie niet herkent, of andersom. Vandaar reference_minutes():
--   één functie, twee aanroepers, zelfde antwoord.
--
-- WAT HIER NIET GEBEURT
--   invoice_lines() blijft ongemoeid. Als BENU op de PDA-tijd gefactureerd moet
--   worden, verandert dat de bedragen, en dat is een aparte beslissing.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────
-- 1. De PDA-tijd bij de declaratie.
--    Nullable, en dat blijft zo: alleen BENU selfbilling-diensten hebben een
--    PDA. Bij de rest hoort hier niets te staan, en een NOT NULL zou elke
--    bestaande declaratie ongeldig maken.
-- ────────────────────────────────────────────────────────────────────────
ALTER TABLE public.shift_declarations ADD COLUMN IF NOT EXISTS pda_start TIME;
ALTER TABLE public.shift_declarations ADD COLUMN IF NOT EXISTS pda_end   TIME;

COMMENT ON COLUMN public.shift_declarations.pda_start IS
  'Begintijd volgens de PDA van de BENU-apotheek; NULL bij een niet-BENU-dienst.';
COMMENT ON COLUMN public.shift_declarations.pda_end IS
  'Eindtijd volgens de PDA van de BENU-apotheek; NULL bij een niet-BENU-dienst.';


-- ────────────────────────────────────────────────────────────────────────
-- 2. declaration_is_benu — heeft deze dienst een BENU selfbilling-filiaal?
--    Eén filiaal is genoeg: de PDA-tijd geldt voor de hele route, en die route
--    is er één. Aparte functie zodat de drie plekken die het moeten weten —
--    submit, sweep en de invulpagina — niet elk hun eigen EXISTS schrijven.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.declaration_is_benu(p_shift_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT EXISTS (
    SELECT 1
    FROM public.shift_pharmacies sp
    JOIN public.pharmacies p ON p.id = sp.pharmacy_id
    WHERE sp.shift_id = p_shift_id AND p.is_benu_selfbilling
  );
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 3. reference_minutes — waartegen meten we de uitloop?
--
--    BENU met een PDA-tijd → de PDA-tijd. Anders de begrote tijd. Is er geen
--    van beide, dan NULL: er valt dan niets te overschrijden, en er hoort dus
--    ook niet om een verklaring gevraagd te worden.
--
--    De volgorde is niet willekeurig. Een BENU-dienst waarvan de PDA-tijd nog
--    niet is ingevuld valt terug op de begrote tijd in plaats van op niets —
--    dat betreft de declaraties van vóór deze migratie, en die horen niet stil
--    buiten de meerwerk-keten te vallen.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.reference_minutes(
  p_is_benu    BOOLEAN,
  p_pda_start  TIME, p_pda_end  TIME,
  p_plan_start TIME, p_plan_end TIME
)
RETURNS INT
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT CASE
    WHEN p_is_benu AND p_pda_start IS NOT NULL AND p_pda_end IS NOT NULL
      THEN public.duration_minutes(p_pda_start, p_pda_end)
    WHEN p_plan_end IS NOT NULL
      THEN public.duration_minutes(p_plan_start, p_plan_end)
  END;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 4. declaration_submit — de PDA-tijd erbij.
--
--    De twee nieuwe parameters staan ACHTERAAN met DEFAULT NULL, zodat een
--    aanroep met benoemde argumenten die ze niet meegeeft blijft werken. De
--    Edge Function roept met namen aan, dus die breekt niet tijdens de uitrol.
--
--    DROP en CREATE en geen CREATE OR REPLACE: een andere parameterlijst levert
--    een tweede functie op in plaats van een vervanging, en dan is een aanroep
--    met zes argumenten opeens dubbelzinnig.
-- ────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.declaration_submit(TEXT, TIME, TIME, BOOLEAN, NUMERIC, TEXT);

CREATE FUNCTION public.declaration_submit(
  p_token         TEXT,
  p_actual_start  TIME,
  p_actual_end    TIME,
  p_claims_travel BOOLEAN,
  p_own_car_km    NUMERIC DEFAULT NULL,
  p_note          TEXT    DEFAULT NULL,
  p_pda_start     TIME    DEFAULT NULL,
  p_pda_end       TIME    DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_dec       public.shift_declarations;
  v_own_car   BOOLEAN;
  v_km        NUMERIC;
  v_shift     RECORD;
  v_is_benu   BOOLEAN;
  v_pda_start TIME;
  v_pda_end   TIME;
  v_drempel   INT;
  v_referentie INT;
  v_uitloop   INT;
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

  IF p_actual_start IS NULL OR p_actual_end IS NULL THEN
    RAISE EXCEPTION 'Vul zowel de begintijd als de eindtijd in.';
  END IF;

  SELECT s.start_time, s.budgeted_end_time, s.shift_type,
         s.transport_mode = 'car' AND s.car_is_own IS TRUE AS own_car
    INTO v_shift
    FROM public.shifts s WHERE s.id = v_dec.shift_id;

  v_is_benu := public.declaration_is_benu(v_dec.shift_id);

  -- ── De PDA-tijd ─────────────────────────────────────────────────────────
  -- Alleen bij BENU. Bij een gewone apotheek is er geen PDA, en wat er dan
  -- toch wordt meegestuurd wordt weggegooid in plaats van opgeslagen: een
  -- kolom die bij de helft iets anders betekent is later niet meer te lezen.
  IF v_is_benu THEN
    IF p_pda_start IS NULL OR p_pda_end IS NULL THEN
      RAISE EXCEPTION 'Vul de begintijd en de eindtijd van de PDA in.';
    END IF;
    v_pda_start := p_pda_start;
    v_pda_end   := p_pda_end;
  ELSE
    v_pda_start := NULL;
    v_pda_end   := NULL;
  END IF;

  -- ── Uitloop verantwoorden ───────────────────────────────────────────────
  -- Bij BENU tegen de PDA-tijd, anders tegen de begrote tijd. Dezelfde functie
  -- als extra_work_sweep() gebruikt: wordt er om een verklaring gevraagd, dan
  -- gaat die ook daadwerkelijk ergens heen.
  IF v_shift.shift_type <> 'urgent' THEN
    v_referentie := public.reference_minutes(
      v_is_benu, v_pda_start, v_pda_end, v_shift.start_time, v_shift.budgeted_end_time);

    IF v_referentie IS NOT NULL THEN
      SELECT extra_work_threshold_minutes INTO v_drempel
        FROM public.invoice_settings WHERE id;

      v_uitloop := public.duration_minutes(p_actual_start, p_actual_end) - v_referentie;

      IF v_uitloop >= v_drempel AND btrim(COALESCE(p_note, '')) = '' THEN
        RAISE EXCEPTION
          'Je bent % minuten langer bezig geweest dan de %. Vertel kort waarom — dat leggen we voor aan de apotheek.',
          v_uitloop,
          CASE WHEN v_is_benu THEN 'PDA-tijd' ELSE 'geplande tijd' END;
      END IF;
    END IF;
  END IF;

  v_own_car := v_shift.own_car;
  v_km := CASE WHEN p_claims_travel IS TRUE AND v_own_car THEN p_own_car_km END;

  IF p_claims_travel IS TRUE AND v_own_car AND (v_km IS NULL OR v_km <= 0) THEN
    RAISE EXCEPTION 'Vul het aantal gereden kilometers in.';
  END IF;

  UPDATE public.shift_declarations
     SET actual_start  = p_actual_start,
         actual_end    = p_actual_end,
         pda_start     = v_pda_start,
         pda_end       = v_pda_end,
         claims_travel = COALESCE(p_claims_travel, false),
         own_car_km    = v_km,
         courier_note  = NULLIF(btrim(COALESCE(p_note, '')), ''),
         status        = 'submitted',
         submitted_at  = now()
   WHERE id = v_dec.id;

  PERFORM public.declaration_recompute(v_dec.id);
  RETURN v_dec.id;
END;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 5. extra_work_sweep — dezelfde referentie als het formulier.
--
--    De drempel blijft in de WHERE (migratie 052): een declaratie die eronder
--    blijft hoort niet elk uur opnieuw een plek in de LIMIT te bezetten. De
--    selectie staat nu in een subquery, zodat de referentie één keer berekend
--    wordt en zowel gefilterd als opgeslagen kan worden.
--
--    planned_minutes in extra_work is voortaan de REFERENTIE en niet per se de
--    begroting. Bij een BENU-dienst is dat de PDA-tijd, en dat is precies wat
--    de apotheek te zien krijgt in het verzoek — zij moet kunnen nagaan waar
--    die extra minuten bovenop komen.
--
--    budgeted_end_time IS NOT NULL is vervallen als voorwaarde: een BENU-dienst
--    met een PDA-tijd maar zonder begroting heeft wel degelijk een referentie.
--    Dat gat wordt nu door reference_minutes() zelf bewaakt.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.extra_work_sweep(p_limit INT DEFAULT 200)
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_cfg   public.invoice_settings;
  r       RECORD;
  v_made  INT := 0;
  v_id    UUID;
  v_share NUMERIC;
BEGIN
  SELECT * INTO v_cfg FROM public.invoice_settings WHERE id;

  FOR r IN
    SELECT * FROM (
      SELECT s.id AS shift_id, s.shift_date, sp.pharmacy_id,
             d.id AS declaration_id, d.courier_note,
             public.reference_minutes(
               public.declaration_is_benu(s.id),
               d.pda_start, d.pda_end, s.start_time, s.budgeted_end_time) AS planned,
             public.duration_minutes(d.actual_start, d.actual_end)        AS actual,
             (SELECT count(*) FROM public.shift_pharmacies x WHERE x.shift_id = s.id) AS n_pharmacies,
             (SELECT sum(x.budgeted_minutes) FROM public.shift_pharmacies x WHERE x.shift_id = s.id) AS sum_minutes,
             EXISTS (SELECT 1 FROM public.shift_pharmacies x
                      WHERE x.shift_id = s.id AND x.budgeted_minutes IS NULL) AS any_missing,
             sp.budgeted_minutes
      FROM public.shift_declarations d
      JOIN public.shifts s            ON s.id = d.shift_id
      JOIN public.shift_pharmacies sp ON sp.shift_id = s.id
      WHERE d.actual_start IS NOT NULL
        AND d.actual_end   IS NOT NULL
        AND s.status <> 'draft'
        -- Spoed heeft een vast bedrag; uitloop verandert daar niets aan.
        AND s.shift_type <> 'urgent'
        AND NOT EXISTS (
          SELECT 1 FROM public.extra_work e
          WHERE e.shift_id = s.id AND e.pharmacy_id = sp.pharmacy_id)
    ) q
    WHERE q.planned IS NOT NULL
      AND q.actual - q.planned >= v_cfg.extra_work_threshold_minutes
    ORDER BY q.shift_date
    LIMIT p_limit
  LOOP
    IF r.n_pharmacies <= 1 THEN
      v_share := 1;
    ELSIF r.any_missing OR r.sum_minutes IS NULL OR r.sum_minutes = 0 THEN
      v_share := 1::NUMERIC / r.n_pharmacies;
    ELSE
      v_share := r.budgeted_minutes::NUMERIC / r.sum_minutes;
    END IF;

    INSERT INTO public.extra_work (
      shift_id, pharmacy_id, declaration_id, planned_minutes, actual_minutes,
      extra_minutes, share_pct, share_minutes, courier_note)
    VALUES (
      r.shift_id, r.pharmacy_id, r.declaration_id, r.planned, r.actual,
      r.actual - r.planned, round(v_share * 100, 1),
      round((r.actual - r.planned) * v_share, 1), r.courier_note)
    ON CONFLICT (shift_id, pharmacy_id) DO NOTHING
    RETURNING id INTO v_id;

    IF v_id IS NOT NULL THEN
      v_made := v_made + 1;
      v_id := NULL;
    END IF;
  END LOOP;

  RETURN v_made;
END;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 6. declaration_by_token — de PDA-tijd naar het formulier.
--    DROP en CREATE, want het returntype verandert.
-- ────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.declaration_by_token(TEXT);

CREATE FUNCTION public.declaration_by_token(p_token TEXT)
RETURNS TABLE (
  declaration_id       UUID,
  status               TEXT,
  courier_name         TEXT,
  shift_date           DATE,
  start_time           TEXT,
  budgeted_end_time    TEXT,
  transport_mode       TEXT,
  own_car              BOOLEAN,
  pharmacies           JSONB,
  actual_start         TEXT,
  actual_end           TEXT,
  claims_travel        BOOLEAN,
  own_car_km           NUMERIC,
  courier_note         TEXT,
  submitted_at         TIMESTAMPTZ,
  review_note          TEXT,
  expenses             JSONB,
  expects_receipt      BOOLEAN,
  is_contractor        BOOLEAN,
  is_benu_selfbilling  BOOLEAN,
  explain_over_minutes INT,
  pda_start            TEXT,
  pda_end              TEXT
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
         public.declaration_expects_receipt(d.courier_id),
         public.declaration_is_contractor(d.courier_id),
         public.declaration_is_benu(s.id),
         CASE WHEN s.shift_type <> 'urgent'
              THEN (SELECT extra_work_threshold_minutes FROM public.invoice_settings WHERE id)
         END,
         to_char(d.pda_start, 'HH24:MI'),
         to_char(d.pda_end,   'HH24:MI')
  FROM public.shift_declarations d
  JOIN public.shifts s         ON s.id  = d.shift_id
  JOIN public.user_profiles up ON up.id = d.courier_id
  WHERE d.token_hash = public.declaration_hash_token(p_token)
    AND d.token_expires_at > now();
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 7. Rechten. De drie opnieuw aangemaakte of nieuwe functies.
-- ────────────────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.declaration_by_token(TEXT)                      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.declaration_is_benu(UUID)                       FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.reference_minutes(BOOLEAN, TIME, TIME, TIME, TIME) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.declaration_submit(TEXT, TIME, TIME, BOOLEAN, NUMERIC, TEXT, TIME, TIME)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.declaration_by_token(TEXT)                   TO service_role;
GRANT EXECUTE ON FUNCTION public.declaration_is_benu(UUID)                    TO service_role;
GRANT EXECUTE ON FUNCTION public.reference_minutes(BOOLEAN, TIME, TIME, TIME, TIME) TO service_role;
GRANT EXECUTE ON FUNCTION public.declaration_submit(TEXT, TIME, TIME, BOOLEAN, NUMERIC, TEXT, TIME, TIME)
  TO service_role;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie
-- ────────────────────────────────────────────────────────────────────────

-- Verwacht: pda_start en pda_end staan op de tabel.
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'shift_declarations'
  AND column_name IN ('pda_start', 'pda_end')
ORDER BY column_name;

-- De referentie, vier gevallen naast elkaar.
-- Verwacht: 45 (BENU neemt de PDA-tijd), 30 (geen BENU, dus de begroting),
--           30 (BENU zonder PDA valt terug op de begroting), NULL (niets bekend).
SELECT public.reference_minutes(true,  TIME '09:00', TIME '09:45', TIME '09:00', TIME '09:30') AS benu_met_pda,
       public.reference_minutes(false, NULL,         NULL,         TIME '09:00', TIME '09:30') AS gewone_apotheek,
       public.reference_minutes(true,  NULL,         NULL,         TIME '09:00', TIME '09:30') AS benu_zonder_pda,
       public.reference_minutes(false, NULL,         NULL,         TIME '09:00', NULL)         AS geen_referentie;

-- Verwacht: true — declaration_submit kent de PDA-tijd.
SELECT pg_get_function_arguments(p.oid) LIKE '%p_pda_start%' AS submit_kent_pda
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'declaration_submit';

-- Verwacht: false — de drempel zit nog steeds in de selectie en niet in de lus.
SELECT pg_get_functiondef(p.oid) LIKE '%CONTINUE WHEN%' AS nog_een_continue
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'extra_work_sweep';

-- Verwacht: 0 — de sweep compileert en draait, en met limiet 0 gaat er niets uit.
SELECT public.extra_work_sweep(0) AS meldingen_aangemaakt;

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
