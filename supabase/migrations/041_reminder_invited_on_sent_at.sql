-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — de herinnering verwijst alleen naar een BEZORGDE mail — 041
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 037 eerst.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien, en draai daarna       │
-- │ supabase/tests/037_declaration_reminder_dispatch_test.sql.             │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAT ER MIS WAS
--   invited_on kwam uit shift_declarations.created_at — het moment waarop de
--   declaratie is AANGEMAAKT, dus waarop de uitnodiging in de wachtrij kwam. De
--   herinnering zei daarmee "Vul hem in via de mail van <datum>" op grond van een
--   mail die misschien nooit is bezorgd.
--
--   Waargenomen: een koerier zou een SMS krijgen die verwees naar de mail van
--   09-09, terwijl die mail nog op 'pending' stond omdat de MAIL_ALLOWLIST hem
--   tegenhield. En omdat de herinneringsmail langs dezelfde poort gaat, werd die
--   óók geblokkeerd — een por die naar niets wijst.
--
--   Dat is niet alleen een artefact van de allowlist. Vijf situaties waarin de
--   aanmaakdatum niet het bezorgmoment is, en drie daarvan hebben niets met de
--   poort te maken:
--     1. verstuurd binnen de cyclus van vijf minuten          → datum klopt
--     2. declaratie aangemaakt tussen 23:55 en 00:00           → datum een dag mis
--     3. rij teruggezet door declaration_release()             → uren tot dagen mis
--     4. Brevo-fout → status 'failed', en een failed-rij wordt
--        NOOIT opnieuw aangeboden                              → mail komt nooit
--     5. geen adres of poort dicht → 'pending', daarna
--        'expired' na max_age_days                             → mail komt nooit
--
-- WAT DEZE MIGRATIE DOET
--   invited_on komt nu uit mail_outbox.sent_at van de bijbehorende
--   shift_followup-rij. mail_record_result() (migratie 017) zet dat veld op now()
--   alleen als de verzending lukte, en laat het op NULL bij een mislukking. Dat is
--   exact het onderscheid dat hier nodig is: gevuld betekent "is bezorgd", NULL
--   betekent "is niet bezorgd", en er valt niets te gissen.
--
--   Is het NULL, dan BEWEERT de herinnering geen datum meer. Ze gaat wél uit — de
--   opgave is nodig ongeacht waarom de mail niet aankwam, en een koerier die niets
--   hoort vult niets in, en dan heb je precies het gokprobleem waar deze hele
--   keten voor is gebouwd. Alleen de tekst verwijst dan naar de planning in plaats
--   van naar een mail. Zie de verzenders voor de formulering.
--
--   De runsamenvatting van send-declaration-reminders telt deze gevallen apart
--   (zonder_uitnodiging), zodat een haperende mailketen zichtbaar wordt in plaats
--   van gecamoufleerd achter een herinnering die "gewoon" uitging.
--
-- WAT ER NIET GEBEURT
--   Aan de tokenlogica, de vervaldatum, de momenten en de voorwaarden voor een
--   herinnering verandert niets. De returntypes blijven gelijk, dus CREATE OR
--   REPLACE volstaat en de rechten blijven staan.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;


-- ────────────────────────────────────────────────────────────────────────
-- 1. declaration_reminder_due — invited_on uit het BEZORGMOMENT.
--    Body letterlijk uit migratie 037, met één gewijzigde kolom in de SELECT.
--
--    max() en niet een gewone scalaire subquery: er hoort precies één
--    shift_followup-rij per declaratie te bestaan (declaration_sweep maakt er één,
--    en declaration_release zet diezelfde rij terug in plaats van een nieuwe te
--    maken), maar max() maakt de query onafhankelijk van die aanname en geeft bij
--    nul rijen netjes NULL in plaats van een fout.
--
--    status = 'sent' staat er expliciet bij, ook al is sent_at bij elke andere
--    status NULL. Twee filters die hetzelfde zeggen is hier goedkoper dan een
--    lezer die moet nagaan of dat inderdaad zo is.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.declaration_reminder_due(p_limit INT DEFAULT 200)
RETURNS TABLE (
  declaration_id    UUID,
  stage             SMALLINT,
  courier_id        UUID,
  courier_name      TEXT,
  phone_e164        TEXT,          -- NULL = geen nummer bekend; de verzender meldt dat
  shift_id          UUID,
  shift_date        DATE,
  start_time        TEXT,
  budgeted_end_time TEXT,
  pharmacy_names    TEXT[],
  invited_on        DATE,          -- NULL = de uitnodiging is nooit BEZORGD
  expires_at        TIMESTAMPTZ,
  due_at            TIMESTAMPTZ
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  WITH cfg AS (
    SELECT expected_within_hours FROM public.declaration_settings WHERE id
  ),
  base AS (
    SELECT d.id, d.courier_id, d.token_expires_at,
           s.id AS shift_id, s.shift_date, s.start_time, s.budgeted_end_time,
           public.declaration_shift_end(s.shift_date, s.start_time, s.budgeted_end_time) AS ends_at,
           c.expected_within_hours,
           -- Het moment waarop de uitnodiging werkelijk de deur uit ging.
           (SELECT max(o.sent_at)
              FROM public.mail_outbox o
             WHERE o.kind    = 'shift_followup'
               AND o.status  = 'sent'
               AND o.payload->>'declaration_id' = d.id::TEXT) AS invited_at
    FROM public.shift_declarations d
    JOIN public.shifts s ON s.id = d.shift_id
    CROSS JOIN cfg c
    WHERE d.status = 'open'
      AND d.token_expires_at > now()
  ),
  moments AS (
    SELECT b.*,
           b.ends_at + make_interval(mins => b.expected_within_hours * 30) AS stage1_at,
           LEAST(
             b.ends_at + (b.token_expires_at - b.ends_at) * 0.8::float8,
             b.token_expires_at - INTERVAL '24 hours'
           ) AS stage2_at
    FROM base b
  )
  SELECT m.id,
         pick.st,
         m.courier_id,
         up.name,
         cc.phone_e164,
         m.shift_id,
         m.shift_date,
         to_char(m.start_time, 'HH24:MI'),
         to_char(m.budgeted_end_time, 'HH24:MI'),
         COALESCE(ph.names, '{}'::TEXT[]),
         (m.invited_at AT TIME ZONE 'Europe/Amsterdam')::DATE,
         m.token_expires_at,
         pick.at
  FROM moments m
  JOIN public.user_profiles    up ON up.id = m.courier_id
  LEFT JOIN public.courier_contacts cc ON cc.courier_id = m.courier_id
  LEFT JOIN LATERAL (
    SELECT array_agg(p.name ORDER BY p.name) AS names
    FROM public.shift_pharmacies sp
    JOIN public.pharmacies p ON p.id = sp.pharmacy_id
    WHERE sp.shift_id = m.shift_id
  ) ph ON true
  CROSS JOIN LATERAL (
    SELECT v.st, v.at
    FROM (VALUES (2::SMALLINT, m.stage2_at), (1::SMALLINT, m.stage1_at)) AS v(st, at)
    WHERE v.at <= now()
      AND NOT EXISTS (
        SELECT 1 FROM public.declaration_reminders r
        WHERE r.declaration_id = m.id AND r.stage = v.st
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.declaration_reminders r2
        WHERE r2.declaration_id = m.id AND r2.stage > v.st
      )
    ORDER BY v.st DESC
    LIMIT 1
  ) pick
  ORDER BY pick.at
  LIMIT p_limit;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 2. declaration_reminder_claim — dezelfde bron voor de payload.
--    Body letterlijk uit migratie 037, met één gewijzigd payloadveld. De mail moet
--    hetzelfde weten als de SMS: is de uitnodiging nooit bezorgd, dan staat
--    invited_on op NULL en verwijst ook de mail niet naar een bericht dat er niet
--    is. Twee bronnen voor dezelfde bewering zouden vroeg of laat uiteenlopen.
--
--    shift_date blijft VERPLICHT in de payload: zonder dat veld verloopt de rij
--    nooit, want declaration_expire_stale() vergelijkt erop. Zie migratie 036.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.declaration_reminder_claim(
  p_declaration_id UUID, p_stage SMALLINT
)
RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_rows INT;
  v_dec  RECORD;
BEGIN
  INSERT INTO public.declaration_reminders (declaration_id, stage)
  VALUES (p_declaration_id, p_stage)
  ON CONFLICT DO NOTHING;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RETURN false;
  END IF;

  SELECT d.courier_id, d.token_expires_at,
         s.id AS shift_id, s.shift_date, s.start_time, s.budgeted_end_time,
         up.name AS courier_name,
         (SELECT max(o.sent_at)
            FROM public.mail_outbox o
           WHERE o.kind    = 'shift_followup'
             AND o.status  = 'sent'
             AND o.payload->>'declaration_id' = d.id::TEXT) AS invited_at
    INTO v_dec
  FROM public.shift_declarations d
  JOIN public.shifts s         ON s.id  = d.shift_id
  JOIN public.user_profiles up ON up.id = d.courier_id
  WHERE d.id = p_declaration_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Declaratie % bestaat niet.', p_declaration_id;
  END IF;

  INSERT INTO public.mail_outbox (courier_id, kind, subject_type, subject_id, payload)
  VALUES (
    v_dec.courier_id, 'declaration_reminder', 'shift', v_dec.shift_id,
    jsonb_build_object(
      'declaration_id',    p_declaration_id,
      'stage',             p_stage,
      'courier_name',      v_dec.courier_name,
      'shift_date',        v_dec.shift_date,
      'weekday',           EXTRACT(ISODOW FROM v_dec.shift_date),
      'start_time',        to_char(v_dec.start_time, 'HH24:MI'),
      'budgeted_end_time', to_char(v_dec.budgeted_end_time, 'HH24:MI'),
      'expires_at',        v_dec.token_expires_at,
      -- NULL als de uitnodiging nooit is bezorgd. jsonb_build_object zet dat als
      -- JSON null; de verzender leest dat als "geen datum beweren".
      'invited_on',        (v_dec.invited_at AT TIME ZONE 'Europe/Amsterdam')::DATE,
      'pharmacies',        (SELECT COALESCE(jsonb_agg(p.name ORDER BY p.name), '[]'::jsonb)
                            FROM public.shift_pharmacies sp
                            JOIN public.pharmacies p ON p.id = sp.pharmacy_id
                            WHERE sp.shift_id = v_dec.shift_id)
    ));

  RETURN true;
END;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie
--   1. Per openstaande declaratie: is de uitnodiging bezorgd, en zo ja wanneer.
--      Staat er NULL in bezorgd_op terwijl de outbox-status 'sent' zegt, dan is er
--      iets grondig mis; elke andere status hoort NULL te geven.
--   2. Wat declaration_reminder_due() nu teruggeeft. Een regel met
--      "GEEN UITNODIGING" is geen storing van deze keten maar een signaal over de
--      mailketen — die herinnering gaat wél uit, met een tekst die niet naar een
--      mail verwijst.
-- ────────────────────────────────────────────────────────────────────────
SELECT d.id AS declaration_id,
       s.shift_date,
       d.created_at::DATE          AS uitnodiging_aangemaakt,
       o.status                    AS outbox_status,
       (o.sent_at AT TIME ZONE 'Europe/Amsterdam')::DATE AS bezorgd_op,
       o.error
FROM public.shift_declarations d
JOIN public.shifts s ON s.id = d.shift_id
LEFT JOIN public.mail_outbox o
       ON o.kind = 'shift_followup'
      AND o.payload->>'declaration_id' = d.id::TEXT
WHERE d.status = 'open' AND d.token_expires_at > now()
ORDER BY s.shift_date DESC
LIMIT 20;

SELECT declaration_id, stage, courier_name,
       CASE WHEN phone_e164 IS NULL THEN 'GEEN NUMMER' ELSE 'ok' END AS nummer,
       COALESCE(invited_on::TEXT, 'GEEN UITNODIGING') AS uitnodiging_bezorgd_op,
       shift_date, due_at, expires_at
FROM public.declaration_reminder_due()
ORDER BY due_at;

COMMIT;   -- vervang door ROLLBACK; voor een dry-run zonder op te slaan
