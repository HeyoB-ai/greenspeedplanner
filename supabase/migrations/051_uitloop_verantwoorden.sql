-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — één formulier per dienst, uitloop verantwoorden — 051
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 050 eerst; deze migratie draait een deel daarvan terug.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien.                       │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAAROM 050 MAAR DE HALVE OPLOSSING WAS
--   050 voegde de twee mails samen: het nabericht en de BENU-tijdinvoer in één
--   bericht. Maar de koerier moest daarna nog steeds TWEE formulieren invullen,
--   en dat was de eigenlijke klacht. Eén dienst is één route; daar hoort één
--   opgave bij.
--
-- DE BENU-KETEN DEED HET MEERWERK NOG EEN KEER
--   Migratie 046 bouwde voor BENU selfbilling een eigen keten: een eigen
--   koeriersformulier, een eigen drempel, een eigen goedkeuringslus met de
--   apotheek. Precies dat stond al in migratie 031:
--
--     extra_work_threshold_minutes  standaard 15 — "meer dan een kwartier"
--     extra_work_sweep()            over ELKE declaratie, niet alleen BENU
--     courier_note                  gaat als onderbouwing mee naar de apotheek
--     extra_work_respond_hours      48 uur om te reageren, per filiaal
--
--   Twee ketens voor dezelfde vraag, en de koerier merkte dat als twee
--   formulieren. Wat BENU écht anders maakt is niet de keten maar de HERKOMST
--   van de tijden: die staan op de PDA van de apotheek en niet op de klok van de
--   koerier. Dat is een andere tekst op het bestaande formulier, geen tweede
--   formulier.
--
-- WAT DEZE MIGRATIE DOET
--   1. de BENU-inschrijving uit 050 stopzetten en de wachtende berichten sluiten
--   2. declaration_sweep() terug naar de vorm van 049
--   3. één definitie van "hoe lang duurde dit", gedeeld door de drempel en de
--      meerwerk-sweep, zodat die twee niet uiteen kunnen lopen
--   4. de toelichting VERPLICHT boven de drempel — voor alle koeriers, alle
--      diensten
--   5. het formulier laten weten dát het een BENU-dienst is, en vanaf welke
--      uitloop er een toelichting nodig is
--
-- WAT ER BLIJFT STAAN
--   benu_shift_entries en benu_pharmacy_entries blijven, met hun pagina's en
--   RPC's. Er staan lopende zaken in: formulieren die een koerier nog kan
--   invullen en extra tijd waar een apotheek nog op mag reageren. Die moeten
--   hun ronde kunnen afmaken. Er komen alleen geen NIEUWE meer bij.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────
-- 1. Wachtende BENU-berichten sluiten.
--
--    Moet vóór het droppen van de functies, want benu_expire_stale() verdwijnt
--    hieronder en dit is de laatste kans om deze rijen netjes af te sluiten.
--    Blijven ze op 'pending' staan, dan blijft de verzender ze bij elke ronde
--    aanbieden terwijl send-shift-mail de soort niet meer kent — en dan staat er
--    post in de wachtrij die nooit meer weggaat.
--
--    'benu_time_entry' blijft in de CHECK staan: deze rijen bestaan en een
--    verzamelnaam intrekken waar rijen op staan zou de constraint laten falen.
-- ────────────────────────────────────────────────────────────────────────
UPDATE public.mail_outbox
   SET status = 'expired',
       error  = 'vervallen: de PDA-tijden lopen sinds migratie 051 via de nadeclaratie'
 WHERE kind   = 'benu_time_entry'
   AND status IN ('pending', 'sending');


-- ────────────────────────────────────────────────────────────────────────
-- 2. declaration_sweep — terug naar de vorm van 049.
--    Letterlijk die definitie; het enige verschil met 050 is dat de regel
--    PERFORM public.benu_enqueue_shift(v_shift.id) er weer uit is.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.declaration_sweep(p_limit integer DEFAULT 200)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_cfg   public.declaration_settings;
  v_shift RECORD;
  v_dec   UUID;
  v_made  INT := 0;
BEGIN
  SELECT * INTO v_cfg FROM public.declaration_settings WHERE id;

  FOR v_shift IN
    SELECT s.id, s.courier_id, s.shift_date, s.start_time, s.budgeted_end_time,
           s.transport_mode, s.car_is_own
    FROM public.shifts s
    WHERE s.status = 'planned'
      AND s.courier_id IS NOT NULL
      AND NOT s.sick_leave
      AND s.shift_date >= v_cfg.active_from
      AND s.shift_date >= current_date - v_cfg.max_age_days
      AND public.declaration_shift_end(s.shift_date, s.start_time, s.budgeted_end_time) < now()
      AND NOT EXISTS (
        SELECT 1 FROM public.shift_declarations d WHERE d.shift_id = s.id
      )
    ORDER BY s.shift_date, s.start_time
    LIMIT p_limit
  LOOP
    INSERT INTO public.shift_declarations
      (shift_id, courier_id, token_hash, token_expires_at)
    VALUES
      (v_shift.id, v_shift.courier_id,
       public.declaration_hash_token(public.declaration_new_token()),
       (v_shift.shift_date + v_cfg.token_valid_days)::TIMESTAMP AT TIME ZONE 'Europe/Amsterdam')
    ON CONFLICT (shift_id) DO NOTHING
    RETURNING id INTO v_dec;

    -- Niets teruggekregen = een gelijktijdige sweep was ons voor. Doorlopen.
    CONTINUE WHEN v_dec IS NULL;

    PERFORM public.declaration_recompute(v_dec);

    INSERT INTO public.mail_outbox (courier_id, kind, subject_type, subject_id, payload)
    VALUES (
      v_shift.courier_id, 'shift_followup', 'shift', v_shift.id,
      jsonb_build_object(
        'declaration_id',    v_dec,
        'courier_name',      (SELECT name FROM public.user_profiles WHERE id = v_shift.courier_id),
        'shift_date',        v_shift.shift_date,
        'weekday',           EXTRACT(ISODOW FROM v_shift.shift_date),
        'start_time',        to_char(v_shift.start_time, 'HH24:MI'),
        'budgeted_end_time', to_char(v_shift.budgeted_end_time, 'HH24:MI'),
        'transport_mode',    v_shift.transport_mode,
        'own_car',           v_shift.car_is_own IS TRUE,
        'pharmacies',        (SELECT COALESCE(jsonb_agg(p.name ORDER BY p.name), '[]'::jsonb)
                              FROM public.shift_pharmacies sp
                              JOIN public.pharmacies p ON p.id = sp.pharmacy_id
                              WHERE sp.shift_id = v_shift.id)
      ));

    v_made := v_made + 1;
    v_dec  := NULL;
  END LOOP;

  RETURN v_made;
END;
$function$;


-- ────────────────────────────────────────────────────────────────────────
-- 3. De inschrijfkant van 050 weg.
--    De pagina's van 046 (benu_entry_by_courier_token, benu_entry_submit,
--    benu_pharmacy_by_token, benu_pharmacy_respond, benu_check_deadlines)
--    blijven staan voor de lopende zaken; alleen wat NIEUWE formulieren
--    aanmaakte gaat eruit.
-- ────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.benu_enqueue_due(INT);
DROP FUNCTION IF EXISTS public.benu_enqueue_shift(UUID);
DROP FUNCTION IF EXISTS public.benu_link_for(UUID);
DROP FUNCTION IF EXISTS public.benu_expire_stale();
DROP FUNCTION IF EXISTS public.benu_token_expires(DATE);
-- Uit 046; hier hing alleen send-benu-daily-mail aan, en die functie is weg.
DROP FUNCTION IF EXISTS public.benu_shifts_to_mail();


-- ────────────────────────────────────────────────────────────────────────
-- 4. duration_minutes — één definitie van "hoe lang duurde dit".
--
--    Stond twee keer inline in extra_work_sweep() (migratie 031) en zou nu een
--    derde keer in declaration_submit() komen. Dat is precies de som die niet
--    mag uiteenlopen: als de drempel bij het indienen anders rekent dan de
--    sweep, wordt een koerier om een toelichting gevraagd die nergens heen gaat,
--    of gaat er een verzoek naar de apotheek zonder onderbouwing.
--
--    Een eindtijd op of vóór de begintijd betekent over middernacht heen —
--    dezelfde behandeling als in declaration_shift_end() (migratie 019).
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.duration_minutes(p_start TIME, p_end TIME)
RETURNS INT
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT (EXTRACT(EPOCH FROM (p_end - p_start
           + CASE WHEN p_end <= p_start THEN INTERVAL '1 day' ELSE INTERVAL '0' END)) / 60)::INT;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 5. extra_work_sweep — dezelfde functie, nu met de gedeelde som.
--    Verder letterlijk de definitie uit migratie 031: alleen de twee inline
--    berekeningen zijn vervangen door duration_minutes().
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
    SELECT s.id AS shift_id, sp.pharmacy_id, d.id AS declaration_id, d.courier_note,
           public.duration_minutes(s.start_time, s.budgeted_end_time) AS planned,
           public.duration_minutes(d.actual_start, d.actual_end)      AS actual,
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
      AND s.budgeted_end_time IS NOT NULL
      AND s.status <> 'draft'
      -- Spoed heeft een vast bedrag; uitloop verandert daar niets aan en er valt
      -- dus ook niets goed te keuren.
      AND s.shift_type <> 'urgent'
      AND NOT EXISTS (
        SELECT 1 FROM public.extra_work e
        WHERE e.shift_id = s.id AND e.pharmacy_id = sp.pharmacy_id)
    ORDER BY s.shift_date
    LIMIT p_limit
  LOOP
    CONTINUE WHEN r.actual - r.planned < v_cfg.extra_work_threshold_minutes;

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
-- 6. declaration_submit — de toelichting is verplicht boven de drempel.
--
--    Letterlijk de definitie uit migratie 022, met één blok erbij. De
--    voorwaarden zijn exact die van extra_work_sweep(), en dat is geen toeval:
--    wordt er om een toelichting gevraagd, dan gaat die ook echt ergens heen.
--      * geen begrote eindtijd → geen "langer dan gepland", dus geen vraag;
--      * shift_type 'urgent'   → vast bedrag, uitloop verandert daar niets aan.
--
--    GEEN 45xxx-code. Die klasse betekent in de Edge Function "geldig token maar
--    afgesloten", en dan klapt het formulier dicht. Dit is juist een invoerfout
--    die de koerier zelf kan herstellen; met de gewone P0001 komt de melding
--    onder de knop te staan en blijft alles ingevuld.
--
--    Het aantal minuten staat in de melding. "Vul een toelichting in" laat de
--    koerier raden waar het over gaat; "je bent 23 minuten langer bezig geweest"
--    vertelt hem meteen of hij zich vergist heeft in de tijden.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.declaration_submit(
  p_token         TEXT,
  p_actual_start  TIME,
  p_actual_end    TIME,
  p_claims_travel BOOLEAN,
  p_own_car_km    NUMERIC DEFAULT NULL,
  p_note          TEXT    DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_dec      public.shift_declarations;
  v_own_car  BOOLEAN;
  v_km       NUMERIC;
  v_shift    RECORD;
  v_drempel  INT;
  v_uitloop  INT;
BEGIN
  -- Stap 1: alleen op de hash. Geen status- en geen vervalfilter, anders is
  -- "onbekend" niet te onderscheiden van "bestaat wel, mag niet meer".
  SELECT d.* INTO v_dec
  FROM public.shift_declarations d
  WHERE d.token_hash = public.declaration_hash_token(p_token);

  -- Stap 2: onbekend token houdt de nietszeggende melding.
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Deze link is niet (meer) geldig.' USING ERRCODE = '28000';
  END IF;

  -- Stap 3: het token is geldig, dus de houder mag weten hoe zijn eigen
  -- declaratie ervoor staat.
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

  -- ── Uitloop verantwoorden ───────────────────────────────────────────────
  IF v_shift.budgeted_end_time IS NOT NULL AND v_shift.shift_type <> 'urgent' THEN
    SELECT extra_work_threshold_minutes INTO v_drempel
      FROM public.invoice_settings WHERE id;

    v_uitloop := public.duration_minutes(p_actual_start, p_actual_end)
               - public.duration_minutes(v_shift.start_time, v_shift.budgeted_end_time);

    IF v_uitloop >= v_drempel AND btrim(COALESCE(p_note, '')) = '' THEN
      RAISE EXCEPTION
        'Je bent % minuten langer bezig geweest dan gepland. Vertel kort waarom — dat leggen we voor aan de apotheek.',
        v_uitloop;
    END IF;
  END IF;

  v_own_car := v_shift.own_car;

  -- Kilometers alleen bij een eigen auto én een claim.
  v_km := CASE WHEN p_claims_travel IS TRUE AND v_own_car THEN p_own_car_km END;

  IF p_claims_travel IS TRUE AND v_own_car AND (v_km IS NULL OR v_km <= 0) THEN
    RAISE EXCEPTION 'Vul het aantal gereden kilometers in.';
  END IF;

  UPDATE public.shift_declarations
     SET actual_start  = p_actual_start,
         actual_end    = p_actual_end,
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
-- 7. declaration_by_token — twee velden erbij voor het formulier.
--
--    is_benu_selfbilling: staat er ten minste één BENU selfbilling-filiaal op
--    deze dienst, dan komen de tijden van de PDA van de apotheek en niet van de
--    klok van de koerier. Het formulier zegt dat dan met zoveel woorden; zonder
--    die zin vult de helft zijn eigen tijden in en klopt de facturatie niet.
--
--    explain_over_minutes: vanaf hoeveel minuten uitloop er een toelichting
--    nodig is. Komt uit invoice_settings en niet uit een getal in de pagina,
--    zodat het scherm dezelfde drempel hanteert als declaration_submit() en
--    extra_work_sweep(). Wordt de drempel ooit bijgesteld, dan verschuift het
--    formulier mee.
--
--    DROP en CREATE, want het returntype verandert — zelfde aanpak als 035.
-- ────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.declaration_by_token(TEXT);

CREATE FUNCTION public.declaration_by_token(p_token TEXT)
RETURNS TABLE (
  declaration_id      UUID,
  status              TEXT,
  courier_name        TEXT,
  shift_date          DATE,
  start_time          TEXT,
  budgeted_end_time   TEXT,
  transport_mode      TEXT,
  own_car             BOOLEAN,
  pharmacies          JSONB,
  actual_start        TEXT,
  actual_end          TEXT,
  claims_travel       BOOLEAN,
  own_car_km          NUMERIC,
  courier_note        TEXT,
  submitted_at        TIMESTAMPTZ,
  review_note         TEXT,
  expenses            JSONB,
  expects_receipt     BOOLEAN,
  is_contractor       BOOLEAN,
  is_benu_selfbilling BOOLEAN,
  explain_over_minutes INT
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
         EXISTS (SELECT 1
                   FROM public.shift_pharmacies sp
                   JOIN public.pharmacies p ON p.id = sp.pharmacy_id
                  WHERE sp.shift_id = s.id AND p.is_benu_selfbilling),
         -- NULL bij een spoeddienst of zonder begrote eindtijd: dan is er geen
         -- "langer dan gepland" en hoort het formulier er ook niet om te vragen.
         CASE WHEN s.budgeted_end_time IS NOT NULL AND s.shift_type <> 'urgent'
              THEN (SELECT extra_work_threshold_minutes FROM public.invoice_settings WHERE id)
         END
  FROM public.shift_declarations d
  JOIN public.shifts s         ON s.id  = d.shift_id
  JOIN public.user_profiles up ON up.id = d.courier_id
  WHERE d.token_hash = public.declaration_hash_token(p_token)
    AND d.token_expires_at > now();
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 8. Rechten. CREATE OR REPLACE laat de bestaande ACL staan, maar
--    declaration_by_token is opnieuw aangemaakt en duration_minutes is nieuw.
-- ────────────────────────────────────────────────────────────────────────
REVOKE ALL     ON FUNCTION public.declaration_by_token(TEXT)   FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.declaration_by_token(TEXT)   TO service_role;

REVOKE ALL     ON FUNCTION public.duration_minutes(TIME, TIME) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.duration_minutes(TIME, TIME) TO service_role;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie
-- ────────────────────────────────────────────────────────────────────────

-- Verwacht: geen rijen — de inschrijfkant van 050 is weg.
SELECT p.proname
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('benu_enqueue_shift', 'benu_enqueue_due', 'benu_link_for',
                    'benu_expire_stale', 'benu_token_expires', 'benu_shifts_to_mail');

-- Verwacht: geen rijen — er staat geen BENU-post meer te wachten.
SELECT status, count(*) FROM public.mail_outbox
WHERE kind = 'benu_time_entry' AND status IN ('pending', 'sending')
GROUP BY status;

-- Verwacht: false — declaration_sweep roept de BENU-inschrijving niet meer aan.
SELECT pg_get_functiondef(p.oid) LIKE '%benu_enqueue_shift%' AS roept_benu_nog_aan
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'declaration_sweep';

-- Verwacht: 240, 30, 30 — een gewone dienst, een dienst over middernacht, en
-- een dienst die precies om middernacht eindigt.
SELECT public.duration_minutes(TIME '09:00', TIME '13:00') AS vier_uur,
       public.duration_minutes(TIME '23:45', TIME '00:15') AS over_middernacht,
       public.duration_minutes(TIME '23:30', TIME '00:00') AS tot_middernacht;

-- Verwacht: de twee nieuwe kolommen staan in het resultaat.
SELECT pg_get_function_result(p.oid) LIKE '%is_benu_selfbilling%'  AS heeft_benu_vlag,
       pg_get_function_result(p.oid) LIKE '%explain_over_minutes%' AS heeft_drempel
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'declaration_by_token';

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
