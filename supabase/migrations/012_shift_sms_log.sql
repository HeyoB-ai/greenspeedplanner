-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — SMS-herinnering: log + selectie — migratie 012
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 011 (courier_contacts) eerst.
--
-- Eén SMS, 24 uur vóór aanvang, alleen voor bevestigde diensten met koerier.
-- De garantie "één bericht per dienst" zit NIET in de planning van de job maar
-- in deze tabel: shift_id is de primaire sleutel. Een tweede run, een herstart
-- of twee tegelijk draaiende jobs stuiten op de sleutel en komen niet langs.
-- ════════════════════════════════════════════════════════════════════════


-- ────────────────────────────────────────────────────────────────────────
-- 1. shift_sms_log — één rij per dienst waarvoor een bericht is geclaimd.
--
--    ON DELETE CASCADE: verdwijnt de dienst, dan verdwijnt de logrij. Dat mag,
--    want deze tabel bestaat om een tweede bericht te voorkomen, niet als
--    archief — en een verwijderde dienst komt nooit terug met hetzelfde id.
--    Gevolg om te weten: een verwijderde en opnieuw aangemaakte dienst is een
--    nieuwe dienst en krijgt dus wél een eigen bericht.
--
--    status 'sending' = geclaimd, provider nog niet bevestigd. Blijft een rij
--    op 'sending' hangen, dan is het proces tussen claimen en versturen
--    gestorven: er is dan géén bericht uitgegaan én er komt er ook geen meer.
--    Dat is de bewuste keuze (fail-closed): liever een gemiste SMS die je in het
--    weekoverzicht ziet dan een dubbele bij de koerier.
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.shift_sms_log (
  shift_id            UUID PRIMARY KEY REFERENCES public.shifts(id) ON DELETE CASCADE,
  courier_id          UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  phone_e164          TEXT NOT NULL,
  status              TEXT NOT NULL DEFAULT 'sending'
                      CHECK (status IN ('sending', 'sent', 'failed')),
  provider_message_id TEXT,
  error               TEXT,
  claimed_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  sent_at             TIMESTAMPTZ
);


-- ────────────────────────────────────────────────────────────────────────
-- 2. RLS — planners lezen mee (statuskolom in het weekoverzicht). Schrijven
--    gebeurt uitsluitend door de job: die draait met de service-role key en
--    via de SECURITY DEFINER-functies hieronder. Bewust géén schrijfpolicy.
-- ────────────────────────────────────────────────────────────────────────
ALTER TABLE public.shift_sms_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "sms_log_privileged_read" ON public.shift_sms_log;
CREATE POLICY "sms_log_privileged_read" ON public.shift_sms_log
  FOR SELECT USING (public.is_privileged());


-- ────────────────────────────────────────────────────────────────────────
-- 3. sms_due_shifts — welke diensten hebben nu een bericht nodig?
--
--    Bewust een INHAAL-SWEEP en geen strak venster: "alles wat binnen p_window_hours
--    begint, nog in de toekomst ligt en nog niet in de log staat". Slaat een run
--    over (job plat, database gepauzeerd), dan pakt de volgende run alles op wat
--    nog niet begonnen is. Alleen diensten die tijdens de storing al gestart zijn
--    vallen af — daar heeft een herinnering ook geen zin meer.
--
--    TIJDZONE: shift_date is een DATE en start_time een TIME zonder zone, dus
--    lokale tijd; de job draait in UTC. Zonder AT TIME ZONE schuift de grens een
--    uur zodra de zomertijd wisselt en krijgt iemand zijn bericht op het
--    verkeerde moment. Daarom hier één keer, in SQL, expliciet omgerekend.
--
--    Een concept ('draft') komt hier per definitie niet doorheen: de filter staat
--    op status = 'planned'. Wordt een concept pas 10 uur van tevoren bevestigd,
--    dan valt hij vanaf dat moment in de sweep en gaat het bericht alsnog uit.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.sms_due_shifts(p_window_hours INT DEFAULT 24)
RETURNS TABLE (
  shift_id          UUID,
  courier_id        UUID,
  courier_name      TEXT,
  phone_e164        TEXT,
  start_at          TIMESTAMPTZ,
  shift_date        DATE,
  start_time        TIME,
  budgeted_end_time TIME,
  pharmacy_names    TEXT[]
)
LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE AS $$
  SELECT
    s.id,
    s.courier_id,
    up.name,
    cc.phone_e164,
    (s.shift_date + s.start_time) AT TIME ZONE 'Europe/Amsterdam',
    s.shift_date,
    s.start_time,
    s.budgeted_end_time,
    COALESCE(ph.names, '{}'::TEXT[])
  FROM public.shifts s
  JOIN public.user_profiles    up ON up.id = s.courier_id
  JOIN public.courier_contacts cc ON cc.courier_id = s.courier_id
  LEFT JOIN LATERAL (
    SELECT array_agg(p.name ORDER BY p.name) AS names
    FROM public.shift_pharmacies sp
    JOIN public.pharmacies p ON p.id = sp.pharmacy_id
    WHERE sp.shift_id = s.id
  ) ph ON true
  WHERE s.status = 'planned'
    AND s.courier_id IS NOT NULL
    AND (s.shift_date + s.start_time) AT TIME ZONE 'Europe/Amsterdam' >  now()
    AND (s.shift_date + s.start_time) AT TIME ZONE 'Europe/Amsterdam' <= now() + make_interval(hours => p_window_hours)
    AND NOT EXISTS (SELECT 1 FROM public.shift_sms_log l WHERE l.shift_id = s.id)
  ORDER BY 5;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 4. sms_claim_shift — claim-dan-versturen.
--    Eerst de logrij, dan pas de provider aanroepen. Geeft false terug als een
--    andere run de dienst al had; die run slaat hem dan over. De ON CONFLICT
--    maakt dit atomair, ook bij twee gelijktijdige jobs.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.sms_claim_shift(
  p_shift_id UUID, p_courier_id UUID, p_phone TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rows INT;
BEGIN
  INSERT INTO public.shift_sms_log (shift_id, courier_id, phone_e164, status)
  VALUES (p_shift_id, p_courier_id, p_phone, 'sending')
  ON CONFLICT (shift_id) DO NOTHING;
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows = 1;
END;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 5. sms_record_result — uitkomst van de provider terugschrijven.
--    Een 'failed'-rij blijft staan en blokkeert dus verdere pogingen. Bewust:
--    een automatische herkansing kan niet zien of een time-out "niet verstuurd"
--    of "wél verstuurd, antwoord kwijt" betekende. Handmatig herkansen = de
--    logrij verwijderen (zie README).
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.sms_record_result(
  p_shift_id UUID, p_ok BOOLEAN, p_message_id TEXT DEFAULT NULL, p_error TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  UPDATE public.shift_sms_log
  SET status              = CASE WHEN p_ok THEN 'sent' ELSE 'failed' END,
      provider_message_id = p_message_id,
      error               = p_error,
      sent_at             = CASE WHEN p_ok THEN now() ELSE NULL END
  WHERE shift_id = p_shift_id;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 6. Rechten — deze drie functies zijn uitsluitend voor de job.
--    EXECUTE staat standaard aan voor PUBLIC; dat moet er expliciet af, anders
--    kan elke ingelogde gebruiker (of de anon-key) de nummers uitlezen via
--    sms_due_shifts — die functie omzeilt als SECURITY DEFINER immers RLS.
-- ────────────────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.sms_due_shifts(INT)                         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sms_claim_shift(UUID, UUID, TEXT)           FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sms_record_result(UUID, BOOLEAN, TEXT, TEXT) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.sms_due_shifts(INT)                         TO service_role;
GRANT EXECUTE ON FUNCTION public.sms_claim_shift(UUID, UUID, TEXT)           TO service_role;
GRANT EXECUTE ON FUNCTION public.sms_record_result(UUID, BOOLEAN, TEXT, TEXT) TO service_role;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie — verwacht: geen EXECUTE voor anon/authenticated op de drie
-- functies, en één SELECT-policy op shift_sms_log.
-- ────────────────────────────────────────────────────────────────────────
-- SELECT routine_name, grantee, privilege_type FROM information_schema.routine_privileges
-- WHERE routine_schema = 'public' AND routine_name LIKE 'sms/_%' ESCAPE '/'
-- ORDER BY routine_name, grantee;
--
-- SELECT policyname, cmd, qual FROM pg_policies
-- WHERE schemaname = 'public' AND tablename = 'shift_sms_log';
