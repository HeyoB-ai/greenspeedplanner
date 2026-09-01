-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — goedkeuring van meerwerk door de apotheek — 031
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 030 eerst.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien, en draai daarna       │
-- │ supabase/tests/031_extra_work_test.sql.                                │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- DE KETEN
--   1. Dienst loopt af, koerier krijgt zijn nabericht (fase 6, bestaand).
--   2. Koerier vult werkelijke tijden in met een toelichting (bestaand).
--   3. Is de uitloop minstens een kwartier, dan zet extra_work_sweep() een
--      meerwerkmelding klaar — status 'new'.
--   4. DE PLANNER ZIET DIE EERST en geeft hem vrij. Pas dan komt er een mail in
--      de outbox.
--   5. De apotheek heeft 48 uur om te reageren.
--   6. Goedkeuren of betwisten.
--
-- ┌─ WAAROM DE PLANNER ERTUSSEN ZIT ───────────────────────────────────────┐
-- │ De toelichting van de koerier gaat mee naar de klant. "Duurde langer   │
-- │ omdat het druk was op de weg" is prima; "moest wachten want de          │
-- │ assistente was er niet" is dat niet. De planner moet dat kunnen zien en │
-- │ zo nodig herschrijven vóór het de deur uit gaat.                        │
-- │                                                                        │
-- │ Daarom maakt de sweep wél de melding maar NIET de mail. Er is geen pad  │
-- │ in deze migratie waarlangs een bericht naar een apotheek vertrekt       │
-- │ zonder dat een mens op vrijgeven heeft geklikt.                         │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- ┌─ EN WAT ER NADRUKKELIJK NIET GEBEURT ──────────────────────────────────┐
-- │ De koerier wordt in álle gevallen gewoon uitbetaald. Een geschil met de │
-- │ klant is een geschil tussen Greenspeed en de apotheek; dat mag niet     │
-- │ doorwerken in het loon van iemand die de uren heeft gemaakt. Er is      │
-- │ daarom geen enkele verwijzing vanuit de nadeclaratieketen naar de       │
-- │ status hier, en declaration_compute() is niet aangeraakt.               │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- DE UITKOMSTEN
--   approved  → wordt gefactureerd
--   expired   → wordt óók gefactureerd, maar apart herkenbaar: hier heeft nooit
--               iemand naar gekeken, en daar komt discussie uit voort
--   disputed  → het meerwerk wordt NIET gefactureerd; de geplande uren wel. De
--               regel blijft zichtbaar openstaan tot er telefonisch iets is
--               afgesproken.
--
-- LATER, NIET NU
--   De splitsing keten/filiaal — gebudgetteerde uren naar BENU centraal,
--   meerwerk naar het lokale filiaal — wacht op twee antwoorden (wat er gebeurt
--   bij mínder uren dan gepland, en of het per keten instelbaar wordt). Deze
--   opzet staat die splitsing niet in de weg: het meerwerk zit al in een eigen
--   rij met een eigen apotheek erop, dus er hoeft alleen een ander adres onder.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────
-- 1. Een e-mailadres per apotheek. Zonder adres kan er geen melding uit.
--    Additief en nullable: pharmacies is gedeeld met AIrouteplanner en de
--    bezorg-app.
-- ────────────────────────────────────────────────────────────────────────
ALTER TABLE public.pharmacies
  ADD COLUMN IF NOT EXISTS billing_email TEXT;

ALTER TABLE public.pharmacies
  DROP CONSTRAINT IF EXISTS pharmacies_billing_email_chk;
ALTER TABLE public.pharmacies
  ADD CONSTRAINT pharmacies_billing_email_chk
  CHECK (billing_email IS NULL OR position('@' in billing_email) > 1);

COMMENT ON COLUMN public.pharmacies.billing_email IS
  'Adres waar meerwerkmeldingen heen gaan (migratie 031). Leeg = de melding kan '
  'niet verstuurd worden; die regel wordt dan als onvolledig gemarkeerd, niet '
  'overgeslagen.';

GRANT SELECT (billing_email) ON public.pharmacies TO authenticated;

CREATE OR REPLACE FUNCTION public.set_pharmacy_billing_email(
  p_pharmacy_id TEXT, p_email TEXT
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'Alleen planners mogen het e-mailadres van een apotheek zetten.';
  END IF;

  UPDATE public.pharmacies
     SET billing_email = NULLIF(btrim(COALESCE(p_email, '')), '')
   WHERE id = p_pharmacy_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Geen apotheek met id %.', p_pharmacy_id;
  END IF;
END;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 2. De drempel en de reactietermijn — instelbaar, niet in code.
--    Zonder drempel krijgt een apotheek bij vijf minuten uitloop ook mail, en
--    dan leest niemand het meer.
-- ────────────────────────────────────────────────────────────────────────
ALTER TABLE public.invoice_settings
  ADD COLUMN IF NOT EXISTS extra_work_threshold_minutes INT NOT NULL DEFAULT 15;
ALTER TABLE public.invoice_settings
  ADD COLUMN IF NOT EXISTS extra_work_respond_hours     INT NOT NULL DEFAULT 48;

ALTER TABLE public.invoice_settings
  DROP CONSTRAINT IF EXISTS invoice_settings_extra_work_chk;
ALTER TABLE public.invoice_settings
  ADD CONSTRAINT invoice_settings_extra_work_chk
  CHECK (extra_work_threshold_minutes > 0 AND extra_work_respond_hours > 0);


-- ────────────────────────────────────────────────────────────────────────
-- 3. extra_work — één rij per (dienst, apotheek).
--    Bij een gedeelde dienst krijgt elk filiaal alleen zijn eigen deel van de
--    uitloop te zien, naar rato van budgeted_minutes — dezelfde verdeling als
--    in invoice_lines(), zodat wat de apotheek goedkeurt precies is wat er
--    later op haar factuur staat.
--
--    De toelichting van de koerier wordt bij het aanmaken GEKOPIEERD. Wijzigt
--    de koerier zijn declaratie later, dan verandert niet met terugwerkende
--    kracht wat er aan de klant is voorgelegd.
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.extra_work (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shift_id        UUID NOT NULL REFERENCES public.shifts(id) ON DELETE CASCADE,
  pharmacy_id     TEXT NOT NULL REFERENCES public.pharmacies(id) ON DELETE CASCADE,
  declaration_id  UUID REFERENCES public.shift_declarations(id) ON DELETE SET NULL,

  planned_minutes INT     NOT NULL,   -- van de hele dienst
  actual_minutes  INT     NOT NULL,   -- van de hele dienst
  extra_minutes   INT     NOT NULL,   -- actual - planned, hele dienst
  share_pct       NUMERIC NOT NULL,   -- aandeel van deze apotheek
  share_minutes   NUMERIC NOT NULL,   -- extra_minutes × aandeel

  courier_note    TEXT,               -- kopie, zie hierboven
  planner_note    TEXT,               -- wat er werkelijk naar de klant gaat

  status          TEXT NOT NULL DEFAULT 'new'
                  CHECK (status IN ('new', 'released', 'approved', 'disputed', 'expired')),

  released_at     TIMESTAMPTZ,
  released_by     UUID REFERENCES public.user_profiles(id),
  sent_at         TIMESTAMPTZ,
  respond_by      TIMESTAMPTZ,
  responded_at    TIMESTAMPTZ,
  response_note   TEXT,

  -- Zelfde patroon als de nadeclaratie: alleen de hash, het token wordt bij het
  -- verzenden gemaakt (migratie 019, punt 6).
  token_hash       TEXT UNIQUE,
  token_expires_at TIMESTAMPTZ,

  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (shift_id, pharmacy_id)
);

CREATE INDEX IF NOT EXISTS extra_work_status_idx ON public.extra_work (status);

-- Dicht, net als shift_declarations: er zitten token-hashes in en de
-- apotheekpagina praat uitsluitend met een Edge Function.
ALTER TABLE public.extra_work ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.extra_work FROM PUBLIC, anon, authenticated;


-- ────────────────────────────────────────────────────────────────────────
-- 4. extra_work_sweep — meldingen klaarzetten.
--    Geen mail: die komt pas na vrijgave. De unique op (shift_id, pharmacy_id)
--    is de poort, zoals overal in deze keten.
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
           (EXTRACT(EPOCH FROM (s.budgeted_end_time - s.start_time
             + CASE WHEN s.budgeted_end_time <= s.start_time THEN INTERVAL '1 day' ELSE INTERVAL '0' END)) / 60)::INT AS planned,
           (EXTRACT(EPOCH FROM (d.actual_end - d.actual_start
             + CASE WHEN d.actual_end <= d.actual_start THEN INTERVAL '1 day' ELSE INTERVAL '0' END)) / 60)::INT AS actual,
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
-- 5. extra_work_release — de planner geeft vrij, en pas dán gaat er post uit.
--    planner_note is wat de klant te lezen krijgt. Laat de planner hem leeg,
--    dan gaat de toelichting van de koerier mee zoals hij is — een bewuste
--    keuze van de planner, niet iets wat per ongeluk gebeurt.
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

  -- De outbox-rij. courier_id blijft leeg: dit gaat naar een apotheek, niet naar
  -- een koerier. Het adres staat in recipient_override; zie punt 7.
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
      'note',           v_note));
END;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 6. Verlopen laten verlopen.
--    Draait mee met de verzender. 'expired' is nadrukkelijk iets anders dan
--    'approved': het wordt wél gefactureerd, maar er heeft nooit iemand naar
--    gekeken — en dat is precies waar discussie uit voortkomt.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.extra_work_expire()
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_rows INT;
BEGIN
  UPDATE public.extra_work
     SET status = 'expired'
   WHERE status = 'released'
     AND sent_at IS NOT NULL      -- pas tellen vanaf het moment dat de mail echt weg is
     AND respond_by IS NOT NULL
     AND respond_by < now();

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 7. mail_outbox: post die niet naar een koerier gaat.
--    courier_id wordt nullable en er komt een recipient_override bij. Bestaande
--    rijen hebben allemaal een courier_id, dus voor de keten van fase 5
--    verandert er niets: mail_pending_couriers() joint op user_profiles en ziet
--    deze rijen simpelweg niet.
-- ────────────────────────────────────────────────────────────────────────
ALTER TABLE public.mail_outbox ALTER COLUMN courier_id DROP NOT NULL;
ALTER TABLE public.mail_outbox ADD COLUMN IF NOT EXISTS recipient_override TEXT;

ALTER TABLE public.mail_outbox
  DROP CONSTRAINT IF EXISTS mail_outbox_recipient_chk;
ALTER TABLE public.mail_outbox
  ADD CONSTRAINT mail_outbox_recipient_chk
  CHECK (courier_id IS NOT NULL OR recipient_override IS NOT NULL);

DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT conname, pg_get_constraintdef(oid) AS def
    FROM pg_constraint
    WHERE conrelid = 'public.mail_outbox'::regclass AND contype = 'c'
  LOOP
    IF r.def LIKE '%shift_followup%' THEN
      EXECUTE format('ALTER TABLE public.mail_outbox DROP CONSTRAINT %I', r.conname);
    END IF;
  END LOOP;
END $$;

ALTER TABLE public.mail_outbox
  ADD CONSTRAINT mail_outbox_kind_chk CHECK (kind IN (
    'schedule_confirmed', 'schedule_changed', 'schedule_cancelled',
    'shift_confirmed',    'shift_changed',    'shift_cancelled',
    'shift_followup',     'extra_work_request'));

-- Wie heeft er post die niet naar een koerier gaat.
CREATE OR REPLACE FUNCTION public.mail_pending_direct()
RETURNS TABLE (recipient TEXT, items INT, oldest TIMESTAMPTZ)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT o.recipient_override, count(*)::INT, min(o.created_at)
  FROM public.mail_outbox o
  WHERE o.status = 'pending'
    AND o.courier_id IS NULL
    AND o.recipient_override IS NOT NULL
  GROUP BY o.recipient_override
  ORDER BY min(o.created_at);
$fn$;

-- Een geclaimde bundel terugzetten. declaration_release() uit migratie 019 doet
-- dit ook, maar filtert op kind = 'shift_followup' en zou een meerwerkmelding
-- dus stil op 'sending' laten staan. Deze variant kijkt niet naar de soort: het
-- gaat om rijen die geclaimd zijn maar waarvoor geen bruikbaar bericht te maken
-- was, en die horen terug in de wachtrij.
CREATE OR REPLACE FUNCTION public.mail_release(p_ids UUID[])
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_rows INT;
BEGIN
  UPDATE public.mail_outbox
     SET status = 'pending', claimed_at = NULL
   WHERE id = ANY (p_ids)
     AND status = 'sending';

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$fn$;

-- Claim-dan-versturen, zelfde patroon als mail_claim_for_courier (migratie 017):
-- één UPDATE, dus geen half geclaimde bundel als er twee verzenders draaien.
CREATE OR REPLACE FUNCTION public.mail_claim_direct(p_recipient TEXT)
RETURNS SETOF public.mail_outbox
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $fn$
  UPDATE public.mail_outbox
     SET status = 'sending', claimed_at = now()
   WHERE recipient_override = p_recipient
     AND courier_id IS NULL
     AND status = 'pending'
  RETURNING *;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 8. Het token voor de apotheek — pas bij het verzenden, net als bij de
--    nadeclaratie. In de database staat alleen de hash.
--    Legt meteen sent_at vast: vanaf dat moment loopt de reactietermijn, en
--    niet vanaf de vrijgave — anders verstrijkt de termijn terwijl de mail nog
--    in de wachtrij staat.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.extra_work_issue_token(p_id UUID)
RETURNS TABLE (token TEXT, respond_by TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_row   public.extra_work;
  v_cfg   public.invoice_settings;
  v_token TEXT;
  v_sent  TIMESTAMPTZ;
BEGIN
  SELECT * INTO v_row FROM public.extra_work WHERE id = p_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Geen meerwerkmelding met id %.', p_id;
  END IF;
  IF v_row.status <> 'released' THEN
    RAISE EXCEPTION 'Melding % is niet vrijgegeven (%).', p_id, v_row.status;
  END IF;

  SELECT * INTO v_cfg FROM public.invoice_settings WHERE id;
  v_token := public.declaration_new_token();
  v_sent  := COALESCE(v_row.sent_at, now());

  UPDATE public.extra_work SET
    token_hash = public.declaration_hash_token(v_token),
    sent_at    = v_sent,
    respond_by = v_sent + make_interval(hours => v_cfg.extra_work_respond_hours)
  WHERE id = p_id;

  token      := v_token;
  respond_by := v_sent + make_interval(hours => v_cfg.extra_work_respond_hours);
  RETURN NEXT;
END;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 9. Wat de apotheekpagina mag zien.
--    Ook ná beoordeling: lezen en schrijven zijn twee verschillende vragen, en
--    een link die na goedkeuring "werkt niet meer" zegt is misleidend — dat is
--    de les uit migratie 023. Alleen een verlopen of onbekend token geeft niets.
--
--    Er gaat geen naam van een koerier mee. De apotheek hoeft te weten dát het
--    langer duurde en waarom, niet wie het was.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.extra_work_by_token(p_token TEXT)
RETURNS TABLE (
  extra_work_id  UUID,
  status         TEXT,
  pharmacy_name  TEXT,
  shift_date     DATE,
  planned_start  TEXT,
  planned_end    TEXT,
  extra_minutes  NUMERIC,
  note           TEXT,
  respond_by     TIMESTAMPTZ,
  responded_at   TIMESTAMPTZ,
  response_note  TEXT
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT e.id, e.status, p.name,
         s.shift_date,
         to_char(s.start_time, 'HH24:MI'),
         to_char(s.budgeted_end_time, 'HH24:MI'),
         e.share_minutes,
         COALESCE(e.planner_note, e.courier_note),
         e.respond_by, e.responded_at, e.response_note
  FROM public.extra_work e
  JOIN public.shifts s     ON s.id = e.shift_id
  JOIN public.pharmacies p ON p.id = e.pharmacy_id
  WHERE e.token_hash = public.declaration_hash_token(p_token)
    AND e.token_expires_at > now();
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 10. Het antwoord van de apotheek.
--     Reageren mag ook ná de termijn zolang de link geldig is: een antwoord dat
--     een uur te laat komt is nog steeds een antwoord, en 'expired' met een
--     reactie eronder is nuttiger dan een geweigerde klik.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.extra_work_respond(
  p_token TEXT, p_approve BOOLEAN, p_note TEXT DEFAULT NULL
)
RETURNS TEXT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_row public.extra_work;
BEGIN
  SELECT e.* INTO v_row FROM public.extra_work e
  WHERE e.token_hash = public.declaration_hash_token(p_token);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Deze link is niet (meer) geldig.' USING ERRCODE = '28000';
  END IF;
  IF v_row.token_expires_at <= now() THEN
    RAISE EXCEPTION 'Deze link is verlopen. Neem contact op met Greenspeed.'
      USING ERRCODE = '45001';
  END IF;
  IF v_row.status IN ('approved', 'disputed') THEN
    RAISE EXCEPTION 'Hier is al op gereageerd op %.', to_char(v_row.responded_at, 'DD-MM-YYYY')
      USING ERRCODE = '45004';
  END IF;
  IF v_row.status = 'new' THEN
    -- Kan alleen als iemand een token uit een oude mail hergebruikt nadat de
    -- melding is teruggezet. Dan is er niets om op te reageren.
    RAISE EXCEPTION 'Deze melding staat niet open.' USING ERRCODE = '45004';
  END IF;

  UPDATE public.extra_work SET
    status        = CASE WHEN p_approve THEN 'approved' ELSE 'disputed' END,
    responded_at  = now(),
    response_note = NULLIF(btrim(COALESCE(p_note, '')), '')
  WHERE id = v_row.id;

  RETURN CASE WHEN p_approve THEN 'approved' ELSE 'disputed' END;
END;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 11. Het plannerscherm.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.extra_work_overview(
  p_from DATE DEFAULT NULL, p_to DATE DEFAULT NULL
)
RETURNS TABLE (
  extra_work_id   UUID,
  shift_id        UUID,
  shift_date      DATE,
  pharmacy_id     TEXT,
  pharmacy_name   TEXT,
  billing_email   TEXT,
  courier_name    TEXT,
  planned_minutes INT,
  actual_minutes  INT,
  extra_minutes   INT,
  share_pct       NUMERIC,
  share_minutes   NUMERIC,
  courier_note    TEXT,
  planner_note    TEXT,
  status          TEXT,
  released_at     TIMESTAMPTZ,
  sent_at         TIMESTAMPTZ,
  respond_by      TIMESTAMPTZ,
  responded_at    TIMESTAMPTZ,
  response_note   TEXT
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT e.id, e.shift_id, s.shift_date, e.pharmacy_id, p.name, p.billing_email,
         up.name, e.planned_minutes, e.actual_minutes, e.extra_minutes,
         e.share_pct, e.share_minutes, e.courier_note, e.planner_note, e.status,
         e.released_at, e.sent_at, e.respond_by, e.responded_at, e.response_note
  FROM public.extra_work e
  JOIN public.shifts s     ON s.id = e.shift_id
  JOIN public.pharmacies p ON p.id = e.pharmacy_id
  LEFT JOIN public.user_profiles up ON up.id = s.courier_id
  WHERE public.is_privileged()
    AND (p_from IS NULL OR s.shift_date >= p_from)
    AND (p_to   IS NULL OR s.shift_date <= p_to)
  ORDER BY
    CASE e.status WHEN 'new' THEN 0 WHEN 'released' THEN 1 ELSE 2 END,
    s.shift_date DESC;
$fn$;

-- Terugzetten naar 'new', bijvoorbeeld als de toelichting toch anders moet. Het
-- token wordt gewist: een link die al verstuurd is mag daarna niets meer doen.
CREATE OR REPLACE FUNCTION public.extra_work_reopen(p_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
BEGIN
  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'Alleen planners mogen een melding terugzetten.';
  END IF;

  UPDATE public.extra_work SET
    status = 'new', released_at = NULL, released_by = NULL, sent_at = NULL,
    respond_by = NULL, responded_at = NULL, response_note = NULL,
    token_hash = NULL, token_expires_at = NULL
  WHERE id = p_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Geen meerwerkmelding met id %.', p_id;
  END IF;
END;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 12. Rechten.
-- ────────────────────────────────────────────────────────────────────────
REVOKE ALL     ON FUNCTION public.set_pharmacy_billing_email(TEXT, TEXT)  FROM PUBLIC, anon;
REVOKE ALL     ON FUNCTION public.extra_work_sweep(INT)                   FROM PUBLIC, anon, authenticated;
REVOKE ALL     ON FUNCTION public.extra_work_expire()                     FROM PUBLIC, anon, authenticated;
REVOKE ALL     ON FUNCTION public.extra_work_issue_token(UUID)            FROM PUBLIC, anon, authenticated;
REVOKE ALL     ON FUNCTION public.extra_work_by_token(TEXT)               FROM PUBLIC, anon, authenticated;
REVOKE ALL     ON FUNCTION public.extra_work_respond(TEXT, BOOLEAN, TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL     ON FUNCTION public.mail_pending_direct()                   FROM PUBLIC, anon, authenticated;
REVOKE ALL     ON FUNCTION public.mail_claim_direct(TEXT)                 FROM PUBLIC, anon, authenticated;
REVOKE ALL     ON FUNCTION public.mail_release(UUID[])                    FROM PUBLIC, anon, authenticated;
REVOKE ALL     ON FUNCTION public.extra_work_release(UUID, TEXT)          FROM PUBLIC, anon;
REVOKE ALL     ON FUNCTION public.extra_work_reopen(UUID)                 FROM PUBLIC, anon;
REVOKE ALL     ON FUNCTION public.extra_work_overview(DATE, DATE)         FROM PUBLIC, anon;

GRANT  EXECUTE ON FUNCTION public.set_pharmacy_billing_email(TEXT, TEXT)  TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.extra_work_sweep(INT)                   TO service_role;
GRANT  EXECUTE ON FUNCTION public.extra_work_expire()                     TO service_role;
GRANT  EXECUTE ON FUNCTION public.extra_work_issue_token(UUID)            TO service_role;
GRANT  EXECUTE ON FUNCTION public.extra_work_by_token(TEXT)               TO service_role;
GRANT  EXECUTE ON FUNCTION public.extra_work_respond(TEXT, BOOLEAN, TEXT) TO service_role;
GRANT  EXECUTE ON FUNCTION public.mail_pending_direct()                   TO service_role;
GRANT  EXECUTE ON FUNCTION public.mail_claim_direct(TEXT)                 TO service_role;
GRANT  EXECUTE ON FUNCTION public.mail_release(UUID[])                    TO service_role;
GRANT  EXECUTE ON FUNCTION public.extra_work_release(UUID, TEXT)          TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.extra_work_reopen(UUID)                 TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.extra_work_overview(DATE, DATE)         TO authenticated, service_role;


-- ────────────────────────────────────────────────────────────────────────
-- 13. invoice_lines — alleen goedgekeurd of verlopen meerwerk factureren.
--     Body uit migratie 030, met de meerwerkregel erin. Nieuwe kolommen, dus
--     DROP en CREATE; de rechten staan er onderaan weer.
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
--   1. De instellingen staan er.
--   2. Hoeveel apotheken hebben nog geen e-mailadres — zonder adres kan een
--      melding niet vrijgegeven worden.
--   3. Wat zou de eerstvolgende sweep oppakken.
-- ────────────────────────────────────────────────────────────────────────
SELECT deviation_pct, extra_work_threshold_minutes, extra_work_respond_hours
FROM public.invoice_settings;

SELECT id, name FROM public.pharmacies WHERE billing_email IS NULL ORDER BY name;

SELECT count(*) AS meldingen_klaar
FROM public.shift_declarations d
JOIN public.shifts s            ON s.id = d.shift_id
JOIN public.shift_pharmacies sp ON sp.shift_id = s.id
CROSS JOIN public.invoice_settings c
WHERE d.actual_start IS NOT NULL AND d.actual_end IS NOT NULL
  AND s.budgeted_end_time IS NOT NULL AND s.status <> 'draft' AND s.shift_type <> 'urgent'
  AND (EXTRACT(EPOCH FROM (d.actual_end - d.actual_start)) / 60)
    - (EXTRACT(EPOCH FROM (s.budgeted_end_time - s.start_time)) / 60) >= c.extra_work_threshold_minutes;

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
