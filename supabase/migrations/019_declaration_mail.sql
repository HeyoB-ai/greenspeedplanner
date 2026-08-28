-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — nadeclaratie: de mailketen en de invulpagina — 019
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 018 eerst.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien, en draai daarna       │
-- │ supabase/tests/019_declaration_mail_test.sql.                          │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAT HERGEBRUIKT WORDT EN WAT NIET
--   Hergebruikt: mail_outbox, de dispatch uit 017 en de Edge Function
--   send-shift-mail. Er komt één nieuwe `kind` bij: shift_followup.
--
--   NIET hergebruikt: mail_upcoming_subjects. Die view filtert op
--   mail_is_upcoming() en status = 'planned' — precies het tegenovergestelde van
--   wat hier nodig is, want een nabericht gaat over een dienst die al gewéést
--   is. Ook de courier_announcements-machinerie met covered_variants en
--   superseded_at blijft buiten beeld: die bestaat om herhaalde aankondigingen
--   te vergelijken, en een nabericht is eenmalig per dienst.
--
--   mail_sweep(), mail_upcoming_subjects en mail_is_upcoming worden door deze
--   migratie NIET gewijzigd.
--
-- IDEMPOTENTIE
--   De unique op shift_declarations.shift_id is de poort. Draaien er twee sweeps
--   tegelijk, dan wint er één — zelfde patroon als de ON CONFLICT DO NOTHING in
--   mail_sweep().
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────
-- 1. declaration_settings — één rij met de instellingen van de keten.
--
--    active_from is het belangrijkste veld van deze migratie. Zonder dat vloer-
--    getal pakt de eerste sweep élke afgelopen dienst uit de hele historie op en
--    stuurt daar mail over. Dezelfde valkuil als de vulling onderaan migratie
--    016, en verstuurde mail is niet terug te halen. De standaardwaarde is de
--    installatiedatum: alleen diensten die ná het installeren aflopen tellen mee.
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.declaration_settings (
  id               BOOLEAN PRIMARY KEY DEFAULT true CHECK (id),
  -- Diensten vóór deze datum worden nooit nagevraagd.
  active_from      DATE NOT NULL DEFAULT current_date,
  -- Ouder dan dit aantal dagen? Dan gaat er geen mail meer uit; een verstopte
  -- wachtrij mag niet alsnog over diensten van weken terug gaan berichten.
  max_age_days     INT  NOT NULL DEFAULT 14 CHECK (max_age_days > 0),
  -- Geldigheid van de invullink, gerekend vanaf de dienstdatum.
  token_valid_days INT  NOT NULL DEFAULT 30 CHECK (token_valid_days > 0)
);

INSERT INTO public.declaration_settings (id) VALUES (true) ON CONFLICT DO NOTHING;

ALTER TABLE public.declaration_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "declaration_settings_privileged_read" ON public.declaration_settings;
CREATE POLICY "declaration_settings_privileged_read" ON public.declaration_settings
  FOR SELECT USING (public.is_privileged());

-- Zie migratie 018, punt 10: zonder GRANT struikelt een planner op "permission
-- denied" nog vóór de policy bekeken wordt.
GRANT SELECT ON public.declaration_settings TO authenticated;


-- ────────────────────────────────────────────────────────────────────────
-- 2. mail_outbox: één berichtsoort en één status erbij.
--    Alleen de CHECK-constraints worden verruimd; aan de tabel, de indexen en de
--    functies van 016/017 verandert niets. Bestaande rijen voldoen aan de nieuwe
--    verzamelingen, dus de validatie bij het toevoegen kan niet stuklopen.
--
--    'expired' hoort bij de leeftijdscontrole in punt 5: een bericht dat te oud
--    is geworden moet zichtbaar afgesloten worden, niet stilletjes op 'pending'
--    blijven staan waar het bij elke run opnieuw langskomt.
--
--    De constraints van 016 zijn inline gezet, dus Postgres heeft ze zelf een
--    naam gegeven. We zoeken ze op hun definitie op in plaats van op een naam die
--    we niet hebben opgeschreven.
-- ────────────────────────────────────────────────────────────────────────
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT conname, pg_get_constraintdef(oid) AS def
    FROM pg_constraint
    WHERE conrelid = 'public.mail_outbox'::regclass AND contype = 'c'
  LOOP
    IF r.def LIKE '%schedule_confirmed%' OR r.def LIKE '%''sending''%' THEN
      EXECUTE format('ALTER TABLE public.mail_outbox DROP CONSTRAINT %I', r.conname);
    END IF;
  END LOOP;
END $$;

ALTER TABLE public.mail_outbox
  ADD CONSTRAINT mail_outbox_kind_chk CHECK (kind IN (
    'schedule_confirmed', 'schedule_changed', 'schedule_cancelled',
    'shift_confirmed',    'shift_changed',    'shift_cancelled',
    'shift_followup'));

ALTER TABLE public.mail_outbox
  ADD CONSTRAINT mail_outbox_status_chk CHECK (status IN (
    'pending', 'sending', 'sent', 'failed', 'expired'));


-- ────────────────────────────────────────────────────────────────────────
-- 3. Wanneer is een dienst afgelopen.
--    Spiegelbeeld van mail_is_upcoming() uit 016, met dezelfde tijdzone-
--    behandeling. Twee dingen die daar niet spelen:
--      * budgeted_end_time is nullable. Dan is er geen eindtijd om op te wachten
--        en nemen we de starttijd plus een ruime marge, zodat er nooit gevraagd
--        wordt naar een dienst die nog loopt.
--      * een eindtijd vóór de starttijd betekent over middernacht heen.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.declaration_shift_end(
  p_date DATE, p_start TIME, p_end TIME
)
RETURNS TIMESTAMPTZ
LANGUAGE sql STABLE AS $$   -- STABLE, niet IMMUTABLE: AT TIME ZONE hangt van de tijdzonedatabase af
  SELECT CASE
    WHEN p_end IS NULL          THEN (p_date + p_start + INTERVAL '8 hours')
    WHEN p_end <= p_start       THEN (p_date + p_end   + INTERVAL '1 day')
    ELSE                             (p_date + p_end)
  END AT TIME ZONE 'Europe/Amsterdam';
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 4. declaration_sweep — diensten die af zijn een declaratie en een bericht
--    geven.
--
--    Selecteert bevestigde diensten met een koerier waarvan de eindtijd voorbij
--    is, die binnen het venster vallen (niet vóór active_from, niet ouder dan
--    max_age_days) en die nog geen declaratie hebben.
--
--    Per dienst: een declaratierij (de unique op shift_id is de poort), de
--    berekening erbij, en één outbox-rij. Het bericht draagt alleen het
--    declaration_id — het token wordt pas bij het verzenden gemaakt, zie punt 6.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.declaration_sweep(p_limit INT DEFAULT 200)
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 5. declaration_expire_stale — de leeftijdscontrole in de dispatch.
--    Wachtende naberichten over diensten van langer dan max_age_days geleden
--    gaan op 'expired' met de reden erbij. Zonder dit stuurt een verstopte
--    wachtrij — een kapotte sleutel, een uitstaande allowlist — alsnog mail over
--    diensten van weken terug zodra hij weer loopt.
--
--    De declaratie zelf blijft gewoon staan: de planner kan hem nog behandelen,
--    er gaat alleen geen mail meer over.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.declaration_expire_stale()
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cfg  public.declaration_settings;
  v_rows INT;
BEGIN
  SELECT * INTO v_cfg FROM public.declaration_settings WHERE id;

  UPDATE public.mail_outbox
     SET status = 'expired',
         error  = format('dienst is ouder dan %s dagen', v_cfg.max_age_days)
   WHERE kind   = 'shift_followup'
     AND status = 'pending'
     AND (payload->>'shift_date')::DATE < current_date - v_cfg.max_age_days;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 5b. declaration_release — een geclaimd nabericht terugzetten.
--     De verzender claimt de hele bundel van een koerier in één UPDATE (017) en
--     legt daarna één uitkomst op alle rijen vast. Lukt het niet om voor een
--     nabericht een invullink te maken — geen DECLARATION_URL, of de declaratie
--     is intussen afgehandeld — dan zou dat bericht als 'sent' worden afgevinkt
--     terwijl de tekst nooit is uitgegaan.
--
--     Zo'n rij gaat hier terug naar 'pending' en gaat mee met de volgende run.
--     Blijft het misgaan, dan vangt de leeftijdscontrole hem uiteindelijk af;
--     wachten is hier de veilige kant, want een gemiste mail zie je in de outbox
--     staan en een verdwenen mail niet.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.declaration_release(p_ids UUID[])
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rows INT;
BEGIN
  UPDATE public.mail_outbox
     SET status = 'pending', claimed_at = NULL
   WHERE id = ANY (p_ids)
     AND kind   = 'shift_followup'
     AND status = 'sending';

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 6. declaration_issue_token — het token, pas op het moment van verzenden.
--
--    In de database staat alleen de hash. Zou het token in de outbox-payload
--    staan, dan zou het daar ook ná verzending blijven staan en levert één
--    leesrecht op mail_outbox een stapel werkende links op. Daarom mint de
--    verzender het token: hij vraagt het hier op, krijgt het één keer terug, zet
--    het in de mail, en wat achterblijft is de hash.
--
--    Een nieuwe uitgifte maakt de vorige link ongeldig. Dat is de prijs voor het
--    bovenstaande en is hier goedkoop: een nabericht gaat één keer per dienst uit,
--    en een tweede uitgifte gebeurt alleen als de eerste verzending mislukte.
--
--    De vervaldatum wordt NIET verlengd: die is bij het aanmaken vastgelegd op
--    dienstdatum + token_valid_days en een herverzending mag dat niet oprekken.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.declaration_issue_token(p_declaration_id UUID)
RETURNS TABLE (token TEXT, expires_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_dec   public.shift_declarations;
  v_token TEXT;
BEGIN
  SELECT * INTO v_dec FROM public.shift_declarations WHERE id = p_declaration_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Declaratie % bestaat niet.', p_declaration_id;
  END IF;
  IF v_dec.status NOT IN ('open', 'submitted') THEN
    RAISE EXCEPTION 'Declaratie % is al afgehandeld (%).', p_declaration_id, v_dec.status;
  END IF;
  IF v_dec.token_expires_at <= now() THEN
    RAISE EXCEPTION 'De invullink van declaratie % is verlopen.', p_declaration_id;
  END IF;

  v_token := public.declaration_new_token();

  UPDATE public.shift_declarations
     SET token_hash = public.declaration_hash_token(v_token)
   WHERE id = p_declaration_id;

  token      := v_token;
  expires_at := v_dec.token_expires_at;
  RETURN NEXT;
END;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 7. declaration_by_token — wat de invulpagina mag zien.
--
--    Uitsluitend de gegevens van déze dienst, ter herkenning: datum, apotheek,
--    geplande tijden, vervoermiddel. GEEN persoonsgegevens van anderen, geen
--    andere diensten, geen bedragen of afstanden van het systeem — de koerier
--    hoeft niet te weten wat er berekend is voordat hij invult.
--
--    Een verlopen of afgehandelde declaratie geeft nul rijen: dan bestaat de
--    pagina niet meer. Het verschil tussen "verlopen" en "bestaat niet" wordt
--    bewust niet naar buiten gebracht.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.declaration_by_token(p_token TEXT)
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
  submitted_at      TIMESTAMPTZ
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
         d.claims_travel, d.own_car_km, d.courier_note, d.submitted_at
  FROM public.shift_declarations d
  JOIN public.shifts s        ON s.id = d.shift_id
  JOIN public.user_profiles up ON up.id = d.courier_id
  WHERE d.token_hash = public.declaration_hash_token(p_token)
    AND d.token_expires_at > now()
    AND d.status IN ('open', 'submitted');
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 8. declaration_submit — de invoer van de koerier vastleggen.
--
--    Het token bepaalt de rij; er is geen declaration_id in de aanroep en dus is
--    een token nooit te gebruiken voor een andere dienst dan de zijne.
--
--    Corrigeren mag zolang de planner er niet naar gekeken heeft (status
--    'submitted'). Zodra hij goedgekeurd of betwist is, doet de link niets meer.
--
--    De kilometers tellen alleen als de koerier ook zegt te declareren; anders
--    wordt het veld leeggemaakt. Zonder dat zou een eerder ingevuld getal blijven
--    staan na het uitvinken en stilzwijgend tóch een claim zijn.
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
  v_dec     public.shift_declarations;
  v_own_car BOOLEAN;
  v_km      NUMERIC;
BEGIN
  SELECT d.* INTO v_dec
  FROM public.shift_declarations d
  WHERE d.token_hash = public.declaration_hash_token(p_token)
    AND d.token_expires_at > now()
    AND d.status IN ('open', 'submitted');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Deze link is niet (meer) geldig.' USING ERRCODE = 'invalid_authorization_specification';
  END IF;

  IF p_actual_start IS NULL OR p_actual_end IS NULL THEN
    RAISE EXCEPTION 'Vul zowel de begintijd als de eindtijd in.';
  END IF;

  SELECT s.transport_mode = 'car' AND s.car_is_own IS TRUE INTO v_own_car
  FROM public.shifts s WHERE s.id = v_dec.shift_id;

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
-- 9. Plannerkant — lezen en beoordelen, allebei via een functie.
--    shift_declarations heeft geen enkele policy (migratie 018, punt 10), dus
--    ook een ingelogde planner komt er niet rechtstreeks bij. Deze twee functies
--    zijn de enige ingang en controleren zelf op is_privileged().
--
--    Het overzicht levert het opgegeven én het berekende naast elkaar, met het
--    verschil al uitgerekend, zodat het scherm geen tarieven of drempels hoeft
--    te kennen (die horen in de database, niet in de frontend).
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.declaration_overview(
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
    d.submitted_at, d.reviewed_at,
    (SELECT rp.name FROM public.user_profiles rp WHERE rp.id = d.reviewed_by),
    d.review_note
  FROM public.shift_declarations d
  JOIN public.shifts s         ON s.id  = d.shift_id
  JOIN public.user_profiles up ON up.id = d.courier_id
  LEFT JOIN public.reimbursement_rates r ON r.id = d.rate_id
  WHERE public.is_privileged()
    AND (p_from IS NULL OR s.shift_date >= p_from)
    AND (p_to   IS NULL OR s.shift_date <= p_to)
  ORDER BY s.shift_date DESC, s.start_time DESC;
$$;

CREATE OR REPLACE FUNCTION public.declaration_review(
  p_declaration_id UUID, p_action TEXT, p_note TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'Alleen planners mogen declaraties beoordelen.';
  END IF;
  IF p_action NOT IN ('approve', 'dispute', 'reopen') THEN
    RAISE EXCEPTION 'Onbekende actie: %.', p_action;
  END IF;

  UPDATE public.shift_declarations
     SET status      = CASE p_action
                         WHEN 'approve' THEN 'approved'
                         WHEN 'dispute' THEN 'disputed'
                         ELSE CASE WHEN submitted_at IS NULL THEN 'open' ELSE 'submitted' END
                       END,
         reviewed_at = CASE WHEN p_action = 'reopen' THEN NULL ELSE now() END,
         reviewed_by = CASE WHEN p_action = 'reopen' THEN NULL ELSE auth.uid() END,
         review_note = NULLIF(btrim(COALESCE(p_note, '')), '')
   WHERE id = p_declaration_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Declaratie % bestaat niet.', p_declaration_id;
  END IF;
END;
$$;

-- Hertellen na een gecorrigeerde afstand, een nieuwe standplaats of een nieuw
-- tarief. Goedgekeurde declaraties blijven staan: die zijn uitbetaald en hun
-- rate_id legt vast waarop dat gebeurde.
CREATE OR REPLACE FUNCTION public.declaration_recompute_open()
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id UUID; v_n INT := 0;
BEGIN
  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'Alleen planners mogen hertellen.';
  END IF;

  FOR v_id IN SELECT id FROM public.shift_declarations WHERE status <> 'approved' LOOP
    PERFORM public.declaration_recompute(v_id);
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 10. Rechten.
--     De ketenfuncties zijn uitsluitend voor de job: declaration_by_token en
--     declaration_submit draaien SECURITY DEFINER en zouden vanaf anon een
--     onbeperkte gokmachine op token-hashes zijn. De invulpagina praat daarom
--     met de Edge Function shift-declaration, die de service-role gebruikt.
--     De plannerfuncties zijn voor de ingelogde planner en controleren zelf.
-- ────────────────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.declaration_sweep(INT)                 FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.declaration_expire_stale()             FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.declaration_release(UUID[])            FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.declaration_issue_token(UUID)          FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.declaration_by_token(TEXT)             FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.declaration_submit(TEXT, TIME, TIME, BOOLEAN, NUMERIC, TEXT)
                                                                     FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.declaration_shift_end(DATE, TIME, TIME) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.declaration_overview(DATE, DATE)        FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.declaration_review(UUID, TEXT, TEXT)    FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.declaration_recompute_open()            FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.declaration_sweep(INT)               TO service_role;
GRANT EXECUTE ON FUNCTION public.declaration_expire_stale()           TO service_role;
GRANT EXECUTE ON FUNCTION public.declaration_release(UUID[])          TO service_role;
GRANT EXECUTE ON FUNCTION public.declaration_issue_token(UUID)        TO service_role;
GRANT EXECUTE ON FUNCTION public.declaration_by_token(TEXT)           TO service_role;
GRANT EXECUTE ON FUNCTION public.declaration_submit(TEXT, TIME, TIME, BOOLEAN, NUMERIC, TEXT)
                                                                      TO service_role;
GRANT EXECUTE ON FUNCTION public.declaration_shift_end(DATE, TIME, TIME) TO service_role;
GRANT EXECUTE ON FUNCTION public.declaration_overview(DATE, DATE)      TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.declaration_review(UUID, TEXT, TEXT)  TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.declaration_recompute_open()          TO authenticated, service_role;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie
--   1. de instellingenrij staat er, met de installatiedatum als vloer
--   2. hoeveel diensten zou de eerstvolgende sweep oppakken — dit is het aantal
--      mails dat er uitgaat zodra de cron aan gaat. Loopt dit in de tientallen,
--      zet active_from dan hoger vóór je verder gaat.
--   3. de nieuwe kind en status zijn toegestaan
-- ────────────────────────────────────────────────────────────────────────
SELECT active_from, max_age_days, token_valid_days FROM public.declaration_settings;

SELECT count(*) AS sweep_zou_oppakken
FROM public.shifts s, public.declaration_settings c
WHERE s.status = 'planned'
  AND s.courier_id IS NOT NULL
  AND s.shift_date >= c.active_from
  AND s.shift_date >= current_date - c.max_age_days
  AND public.declaration_shift_end(s.shift_date, s.start_time, s.budgeted_end_time) < now()
  AND NOT EXISTS (SELECT 1 FROM public.shift_declarations d WHERE d.shift_id = s.id);

SELECT conname, pg_get_constraintdef(oid) AS definitie
FROM pg_constraint
WHERE conrelid = 'public.mail_outbox'::regclass AND contype = 'c'
ORDER BY conname;

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
