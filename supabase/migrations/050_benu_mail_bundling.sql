-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — BENU-tijdinvoer via de outbox — 050
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 046 en 049 eerst.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien.                       │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAT HIER MIS WAS
--   Een koerier met een BENU-dienst kreeg twee mails over dezelfde avond: het
--   nabericht ("hoe lang duurde je dienst?") uit declaration_sweep, en een
--   losse mail met de PDA-tijden uit send-benu-daily-mail. Die tweede ging
--   volledig langs mail_outbox heen — eigen selectie, eigen claim, eigen
--   Brevo-aanroep, eigen opmaak. Daardoor kon de bundeling die send-shift-mail
--   al doet er nooit bij.
--
--   Twee mails over dezelfde dienst zijn niet alleen rommelig: ze maken van één
--   handeling twee openstaande taken, en dan blijft er één van liggen.
--
-- DE OPLOSSING: ÉÉN INSCHRIJFMOMENT, ÉÉN VERZENDER
--   De PDA-vraag wordt een gewone outbox-soort ('benu_time_entry') en wordt
--   aangemaakt op HETZELFDE moment als het nabericht: in declaration_sweep, in
--   dezelfde transactie. Beide rijen staan dus samen op 'pending' voordat er een
--   verzender langskomt, en mail_claim_for_courier() pakt ze in één bundel op.
--   Eén mail, twee knoppen.
--
--   send-benu-daily-mail blijft bestaan, maar verstuurt niets meer: die roept
--   alleen nog benu_enqueue_due() aan als VANGNET, voor BENU-diensten die geen
--   nadeclaratie krijgen (status 'assigned', of een dienstdatum vóór
--   declaration_settings.active_from). Zo'n dienst heeft niets om mee te
--   bundelen, dus daar is één losse mail het juiste antwoord.
--
-- HET TOKEN STAAT WÉL IN DE DATABASE
--   Bij het nabericht wordt het token pas bij het verzenden uitgegeven, omdat er
--   in shift_declarations alleen een SHA-256-hash staat. Hier ligt dat anders:
--   benu_shift_entries.courier_token is de plaintext, en de koerierspagina kent
--   maar één token per dienst. Opnieuw uitgeven zou de link in een eerder
--   bericht doden. Daarom geeft benu_link_for() hem alleen terug; er wordt niets
--   geschreven, ook niet bij het verzenden.
--
--   Het token staat daarom NIET in de outbox-payload: dat zou een werkende link
--   zijn die in een tabel blijft liggen nadat de mail allang weg is. De payload
--   draagt alleen benu_entry_id.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────
-- 1. mail_outbox: 'benu_time_entry' erbij.
--    Verruimen kan niet stuklopen op bestaande rijen: die vallen allemaal
--    binnen de nieuwe verzameling.
-- ────────────────────────────────────────────────────────────────────────
ALTER TABLE public.mail_outbox
  DROP CONSTRAINT IF EXISTS mail_outbox_kind_chk;

ALTER TABLE public.mail_outbox
  ADD CONSTRAINT mail_outbox_kind_chk CHECK (kind IN (
    'schedule_confirmed', 'schedule_changed', 'schedule_cancelled',
    'shift_confirmed',    'shift_changed',    'shift_cancelled',
    'shift_followup',     'extra_work_request',
    'declaration_reminder', 'benu_time_entry'));


-- ────────────────────────────────────────────────────────────────────────
-- 2. benu_token_expires — 10:00 de ochtend ná de dienst.
--
--    Stond tot nu toe in TypeScript (nextMorningTenAmsterdam), met een eigen
--    correctie voor zomertijd. Dat is precies het soort som dat je niet twee
--    keer wilt hebben: de sweep en de vangnet-job zouden dan elk hun eigen
--    vervaldatum kunnen berekenen. Postgres kent de tijdzonedatabase al, dus
--    AT TIME ZONE doet het werk — STABLE en niet IMMUTABLE, om dezelfde reden
--    als declaration_shift_end() (migratie 019).
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.benu_token_expires(p_shift_date DATE)
RETURNS TIMESTAMPTZ
LANGUAGE sql STABLE AS $fn$
  SELECT ((p_shift_date + 1) + TIME '10:00') AT TIME ZONE 'Europe/Amsterdam';
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 3. benu_enqueue_shift — formulier klaarzetten én het bericht inschrijven.
--
--    Idempotent via de UNIQUE op benu_shift_entries.shift_id: twee aanroepen
--    naast elkaar leveren samen één formulier en één outbox-rij op. Geeft NULL
--    terug wanneer er niets te doen was — geen BENU-apotheek op de dienst, de
--    koerier is ziek, of het formulier stond er al.
--
--    De voorwaarden zijn letterlijk die van benu_shifts_to_mail() (046, bijge-
--    werkt in 049), op de datum na: die functie kijkt naar vandaag, deze naar
--    één dienst die de aanroeper al heeft uitgekozen.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.benu_enqueue_shift(p_shift_id UUID)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_shift    RECORD;
  v_pharm    JSONB;
  v_entry_id UUID;
  v_ph       JSONB;
BEGIN
  SELECT s.id, s.courier_id, s.shift_date, s.start_time, s.budgeted_end_time
    INTO v_shift
    FROM public.shifts s
   WHERE s.id = p_shift_id
     AND s.courier_id IS NOT NULL
     AND s.status IN ('planned', 'assigned')
     AND NOT s.sick_leave;
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  -- Alleen de BENU selfbilling-apotheken van deze dienst. Staat er geen enkele
  -- op, dan is er niets te vragen.
  SELECT jsonb_agg(jsonb_build_object(
           'pharmacy_id',     p.id,
           'pharmacy_name',   p.name,
           'planned_minutes', sp.budgeted_minutes
         ) ORDER BY p.name)
    INTO v_pharm
    FROM public.shift_pharmacies sp
    JOIN public.pharmacies p ON p.id = sp.pharmacy_id AND p.is_benu_selfbilling
   WHERE sp.shift_id = p_shift_id;
  IF v_pharm IS NULL THEN
    RETURN NULL;
  END IF;

  INSERT INTO public.benu_shift_entries (shift_id, courier_id, token_expires_at)
  VALUES (p_shift_id, v_shift.courier_id, public.benu_token_expires(v_shift.shift_date))
  ON CONFLICT (shift_id) DO NOTHING
  RETURNING id INTO v_entry_id;

  -- Niets teruggekregen = het formulier stond er al, en daarmee is het bericht
  -- er ook al een keer geweest. Niets doen: een tweede outbox-rij zou precies de
  -- dubbele mail opleveren waar deze migratie voor is.
  IF v_entry_id IS NULL THEN
    RETURN NULL;
  END IF;

  FOR v_ph IN SELECT * FROM jsonb_array_elements(v_pharm) LOOP
    INSERT INTO public.benu_pharmacy_entries
      (shift_entry_id, pharmacy_id, pharmacy_name, planned_minutes)
    VALUES (
      v_entry_id,
      v_ph->>'pharmacy_id',
      v_ph->>'pharmacy_name',
      (v_ph->>'planned_minutes')::INT
    );
  END LOOP;

  -- Dezelfde velden als een shift_followup, zodat de verzender er dezelfde zin
  -- van kan maken. Alleen pharmacies bevat hier uitsluitend de BENU-filialen:
  -- de PDA-vraag gaat over die apotheken en niet over de hele dienst.
  INSERT INTO public.mail_outbox (courier_id, kind, subject_type, subject_id, payload)
  VALUES (
    v_shift.courier_id, 'benu_time_entry', 'shift', p_shift_id,
    jsonb_build_object(
      'benu_entry_id',     v_entry_id,
      'courier_name',      (SELECT name FROM public.user_profiles WHERE id = v_shift.courier_id),
      'shift_date',        v_shift.shift_date,
      'weekday',           EXTRACT(ISODOW FROM v_shift.shift_date),
      'start_time',        to_char(v_shift.start_time, 'HH24:MI'),
      'budgeted_end_time', to_char(v_shift.budgeted_end_time, 'HH24:MI'),
      'pharmacies',        (SELECT jsonb_agg(e->>'pharmacy_name')
                            FROM jsonb_array_elements(v_pharm) e)
    ));

  RETURN v_entry_id;
END;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 4. benu_enqueue_due — het vangnet, voor diensten van vandaag die de sweep
--    niet heeft gezien.
--
--    declaration_sweep() dekt de normale gang van zaken, maar niet alles:
--      * status 'assigned' valt buiten die sweep en binnen deze;
--      * een dienstdatum vóór declaration_settings.active_from levert geen
--        declaratie op, en dus ook geen nabericht.
--    Zulke diensten hebben niets om mee te bundelen. Één losse mail met alleen
--    de PDA-vraag is daar het juiste bericht.
--
--    De selectie is die van benu_shifts_to_mail(); het verschil is dat deze
--    functie alleen id's nodig heeft en het echte werk aan benu_enqueue_shift()
--    laat, zodat er één plek is die formulier én bericht aanmaakt.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.benu_enqueue_due(p_limit INT DEFAULT 200)
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_id   UUID;
  v_made INT := 0;
BEGIN
  FOR v_id IN
    SELECT s.id
    FROM public.shifts s
    WHERE s.shift_date = CURRENT_DATE
      AND s.courier_id IS NOT NULL
      AND s.status IN ('planned', 'assigned')
      AND NOT s.sick_leave
      AND EXISTS (
        SELECT 1 FROM public.shift_pharmacies sp
        JOIN public.pharmacies p ON p.id = sp.pharmacy_id AND p.is_benu_selfbilling
        WHERE sp.shift_id = s.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.benu_shift_entries b WHERE b.shift_id = s.id
      )
    ORDER BY s.start_time
    LIMIT p_limit
  LOOP
    IF public.benu_enqueue_shift(v_id) IS NOT NULL THEN
      v_made := v_made + 1;
    END IF;
  END LOOP;

  RETURN v_made;
END;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 5. benu_link_for — het token ophalen bij het verzenden.
--    LEZEN, niet uitgeven: zie de kop. submitted zit erbij zodat de verzender
--    een bericht kan tegenhouden waarvan de koerier het formulier intussen al
--    heeft ingevuld — vragen om iets dat er al is, is erger dan een bericht dat
--    niet komt.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.benu_link_for(p_entry_id UUID)
RETURNS TABLE (courier_token UUID, expires_at TIMESTAMPTZ, submitted BOOLEAN)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT b.courier_token, b.token_expires_at, b.submitted_at IS NOT NULL
  FROM public.benu_shift_entries b
  WHERE b.id = p_entry_id;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 6. benu_expire_stale — de leeftijdscontrole in de dispatch.
--
--    Spiegel van declaration_expire_stale() (019), met twee redenen in plaats
--    van één. Zonder dit stuurt een wachtrij die een tijd heeft stilgestaan —
--    een dichte allowlist, een verkeerd gezet secret — alsnog een vraag over
--    een formulier dat allang gesloten is, of om tijden die er al in staan.
--
--    De reden wordt meegeschreven: 'expired' zonder uitleg laat achteraf niet
--    zien of het formulier dicht was of juist al ingevuld.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.benu_expire_stale()
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_rows INT;
BEGIN
  UPDATE public.mail_outbox o
     SET status = 'expired',
         error  = CASE WHEN b.submitted_at IS NOT NULL
                       THEN 'de PDA-tijden zijn al ingediend'
                       ELSE 'het invulformulier is gesloten' END
    FROM public.benu_shift_entries b
   WHERE b.id::TEXT = o.payload->>'benu_entry_id'
     AND o.kind     = 'benu_time_entry'
     AND o.status   = 'pending'
     AND (b.submitted_at IS NOT NULL OR b.token_expires_at < now());

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 7. declaration_sweep — de PDA-vraag komt er in dezelfde transactie bij.
--
--    Letterlijk de definitie uit migratie 049, met één regel erbij: het
--    PERFORM hieronder. Dat die twee rijen in één transactie ontstaan IS de
--    oplossing — zou de PDA-vraag een eigen moment houden, dan kan een
--    verzender die ertussen doorloopt het nabericht al hebben verstuurd, en
--    staan we weer bij twee mails.
--
--    De volgorde is bewust: eerst het nabericht, dan de PDA-vraag. Beide rijen
--    krijgen dezelfde created_at (now() is de transactietijd), dus de verzender
--    kan er niet op sorteren; die houdt een eigen volgorde per soort aan. Deze
--    volgorde staat er voor wie later de tabel leest.
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

    -- Staat er een BENU selfbilling-apotheek op deze dienst, dan komt de
    -- PDA-vraag hier bij in dezelfde bundel. Geeft NULL terug als er niets te
    -- doen was; dat is de normale uitkomst voor een gewone dienst.
    PERFORM public.benu_enqueue_shift(v_shift.id);

    v_made := v_made + 1;
    v_dec  := NULL;
  END LOOP;

  RETURN v_made;
END;
$function$;


-- ────────────────────────────────────────────────────────────────────────
-- 8. Rechten — uitsluitend voor de job. EXECUTE staat standaard aan voor
--    PUBLIC en deze functies omzeilen als SECURITY DEFINER de RLS;
--    benu_link_for zou anders een werkend token prijsgeven.
-- ────────────────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.benu_token_expires(DATE)      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.benu_enqueue_shift(UUID)      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.benu_enqueue_due(INT)         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.benu_link_for(UUID)           FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.benu_expire_stale()           FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.benu_token_expires(DATE)   TO service_role;
GRANT EXECUTE ON FUNCTION public.benu_enqueue_shift(UUID)   TO service_role;
GRANT EXECUTE ON FUNCTION public.benu_enqueue_due(INT)      TO service_role;
GRANT EXECUTE ON FUNCTION public.benu_link_for(UUID)        TO service_role;
GRANT EXECUTE ON FUNCTION public.benu_expire_stale()        TO service_role;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie
-- ────────────────────────────────────────────────────────────────────────

-- Verwacht: de CHECK bevat 'benu_time_entry'.
SELECT pg_get_constraintdef(oid) AS kind_check
FROM pg_constraint
WHERE conrelid = 'public.mail_outbox'::regclass AND conname = 'mail_outbox_kind_chk';

-- Verwacht: vijf functies, alle vijf SECURITY DEFINER behalve benu_token_expires
-- (die leest niets en hoeft het niet te zijn).
SELECT p.proname, p.prosecdef AS security_definer
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('benu_token_expires', 'benu_enqueue_shift', 'benu_enqueue_due',
                    'benu_link_for', 'benu_expire_stale')
ORDER BY p.proname;

-- Verwacht: geen rijen — anon en authenticated komen er niet bij.
SELECT routine_name, grantee, privilege_type
FROM information_schema.routine_privileges
WHERE routine_schema = 'public' AND routine_name LIKE 'benu/_%' ESCAPE '/'
  AND grantee IN ('anon', 'authenticated')
ORDER BY routine_name, grantee;

-- Zomertijd-controle: 25-10 is de nacht waarin de klok terugloopt, 28-03 die
-- waarin hij vooruit gaat. Verwacht: beide op 10:00 Amsterdamse tijd.
SELECT public.benu_token_expires(DATE '2026-10-24') AT TIME ZONE 'Europe/Amsterdam' AS na_winteruur,
       public.benu_token_expires(DATE '2026-03-28') AT TIME ZONE 'Europe/Amsterdam' AS na_zomeruur;

-- Proefdraaien zonder iets te versturen: wat zou er vanavond ingeschreven
-- worden? (Dit schrijft wél; alleen binnen een ROLLBACK uitvoeren.)
-- SELECT public.benu_enqueue_due();

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
