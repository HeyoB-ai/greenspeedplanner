-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — wie krijgt een herinnering, en het claimen ervan — 037
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 036 eerst: die zet de termijnen, de berichtsoort en de tabel.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien, en draai daarna       │
-- │ supabase/tests/037_declaration_reminder_dispatch_test.sql.             │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAAROM DRIE FUNCTIES EN GEEN ENKELE QUERY IN DE EDGE FUNCTION
--   Dezelfde verdeling als de SMS-keten van migratie 012: selecteren, claimen,
--   uitkomst vastleggen. De verzender weet dan niets over de voorwaarden, en de
--   voorwaarden staan op één plek in plaats van verspreid over SQL en TypeScript.
--
-- DE MOMENTEN KOMEN UIT DE DATABASE
--   Geen enkel getal staat hier hard. stage 1 leest expected_within_hours,
--   stage 2 rekent met token_expires_at. Zet iemand de termijn op 72 uur of de
--   geldigheid op 10 dagen, dan schuiven de momenten mee zonder dat hier iets
--   verandert.
--
-- ⚠ WAT DE ONDERGRENS OP STAGE 2 NU FEITELIJK DOET
--   De regel is: het vroegste van (80% van de tijd tussen afloop en verlopen) en
--   (token_expires_at − 24 uur). Met token_valid_days = 5 wint die tweede
--   ALTIJD, en is de 80%-term dus nooit werkzaam. Reken mee met een dienst die
--   om 21:00 eindigt: verlopen is (dienstdatum + 5) om middernacht, dus het
--   venster is 99 uur. 80% daarvan is 79,2 uur → 19,8 uur speling. De ondergrens
--   geeft er 24. Pas boven een venster van 120 uur (token_valid_days ≥ 6 bij een
--   late dienst) gaat de 80%-term het overnemen.
--
--   Gevolg voor de verwachting: de koerier houdt precies 24 uur over, geen
--   anderhalve dag. Wil je meer lucht, dan is dat één getal in punt 1
--   ('24 hours' → '36 hours'), niet een andere formule. Beide termen blijven
--   staan omdat de regel zo is afgesproken en zichzelf herstelt zodra de
--   geldigheid omhoog gaat.
--
-- WAT ER NIET GEBEURT
--   * Geen declaration_issue_token(). Die overschrijft token_hash, en een verse
--     link maakt de link in de oorspronkelijke uitnodiging dood — precies bij de
--     koeriers die we met een herinnering wilden bereiken.
--   * Geen wijziging aan declaration_by_token(), declaration_submit() of de
--     invulpagina.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;


-- ────────────────────────────────────────────────────────────────────────
-- 1. declaration_reminder_due — wie is er nu aan de beurt.
--
--    VOORWAARDEN, beide hard:
--      status = 'open'            — wie al iets doorgaf mag corrigeren, maar
--                                   hoeft niet herinnerd te worden
--      token_expires_at > now()   — een herinnering voor een dode link is een
--                                   uitnodiging om te bellen, niet om in te vullen
--
--    ÉÉN RIJ PER DECLARATIE, EN DAT IS DE HOOGSTE STAP DIE OPEN STAAT.
--    Normaal wordt stage 1 eerst opeisbaar en gaat die dus als eerste uit. Heeft
--    de job een tijd stilgestaan en zijn beide momenten intussen verstreken, dan
--    komt alleen stage 2 naar buiten en wordt stage 1 overgeslagen — die krijgt
--    dan ook geen rij. Dat is opzet: twee berichten in dezelfde minuut is erger
--    dan één, en van de twee is stage 2 de nuttigste, want die noemt de
--    vervaldatum. De ORDER BY v.st DESC met LIMIT 1 is die keuze.
--
--    Daar hoort een tweede voorwaarde bij, en die is niet cosmetisch: een stap
--    komt alleen naar buiten als er geen HOGERE stap al gedaan is. Zonder dat zou
--    een overgeslagen stage 1 blijven liggen als een openstaande stap met een
--    verstreken moment, en dus bij de volgende run alsnog uitgaan — ná de mail
--    die zei dat het de laatste herinnering was.
--
--    phone_e164 komt uit een LEFT JOIN en mag NULL zijn. Dat is bewust geen
--    filter: alle koeriers hóren een nummer te hebben, dus een ontbrekend nummer
--    is een fout in de gegevens. De verzender meldt hem met naam en id. Zou hier
--    een INNER JOIN staan — zoals in sms_due_shifts() — dan verdween die koerier
--    stilzwijgend en zag niemand het.
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
  invited_on        DATE,          -- de dag waarop de uitnodiging is aangemaakt
  expires_at        TIMESTAMPTZ,
  due_at            TIMESTAMPTZ
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  WITH cfg AS (
    SELECT expected_within_hours FROM public.declaration_settings WHERE id
  ),
  base AS (
    SELECT d.id, d.courier_id, d.token_expires_at, d.created_at,
           s.id AS shift_id, s.shift_date, s.start_time, s.budgeted_end_time,
           -- Dezelfde definitie van "de dienst is af" als de sweep gebruikt
           -- (migratie 019, punt 3), inclusief de tijdzone en het geval waarin de
           -- eindtijd over middernacht heen ligt.
           public.declaration_shift_end(s.shift_date, s.start_time, s.budgeted_end_time) AS ends_at,
           c.expected_within_hours
    FROM public.shift_declarations d
    JOIN public.shifts s ON s.id = d.shift_id
    CROSS JOIN cfg c
    WHERE d.status = 'open'
      AND d.token_expires_at > now()
  ),
  moments AS (
    SELECT b.*,
           -- De helft van de verwachte termijn, in minuten zodat een oneven
           -- aantal uren geen half uur kwijtraakt op integerdeling.
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
         (m.created_at AT TIME ZONE 'Europe/Amsterdam')::DATE,
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
      -- Deze stap is nog niet gedaan …
      AND NOT EXISTS (
        SELECT 1 FROM public.declaration_reminders r
        WHERE r.declaration_id = m.id AND r.stage = v.st
      )
      -- … en er is geen HOGERE stap al gedaan. Zonder deze tweede voorwaarde komt
      -- stage 1 na een verstuurde stage 2 alsnog naar buiten: die stap heeft dan
      -- immers nog geen rij en zijn moment is al lang voorbij. De koerier krijgt
      -- dan ná "dit is de laatste herinnering" nog een gewone herinnering, en dat
      -- is precies één bericht te veel en het verkeerde.
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
-- 2. declaration_reminder_claim — claimen én de mail in de wachtrij zetten.
--
--    De logrij komt vóór alles, zoals bij de SMS en de mail: de primary key op
--    (declaration_id, stage) is de idempotentie. Nul rijen ingevoegd betekent dat
--    een andere run ons voor was → false, en de verzender slaat over.
--
--    WAAROM DE MAIL HIER WORDT INGESCHREVEN EN NIET IN DE VERZENDER
--    Twee redenen. Ten eerste zit het dan in dezelfde transactie als de claim:
--    een geclaimde herinnering zonder mail, of een mail zonder claim, kan niet
--    bestaan. Ten tweede is de payload dan gegarandeerd volledig — en dat is geen
--    netheid maar een eis: zonder shift_date verloopt de outbox-rij NOOIT, want
--    declaration_expire_stale() vergelijkt op (payload->>'shift_date')::DATE en
--    NULL valt buiten elke vergelijking. Die val ligt niet in TypeScript.
--
--    expires_at gaat mee omdat de mail een DATUM moet noemen en geen aantal
--    dagen. Hem afleiden in de verzender zou betekenen dat token_valid_days daar
--    ook bekend moet zijn, en dan staat de termijn op twee plekken.
--
--    De SMS wordt hier NIET aangeroepen: dat is een netwerkactie en die hoort
--    niet in een databasetransactie.
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

  SELECT d.courier_id, d.token_expires_at, d.created_at,
         s.id AS shift_id, s.shift_date, s.start_time, s.budgeted_end_time,
         up.name AS courier_name
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
      'invited_on',        (v_dec.created_at AT TIME ZONE 'Europe/Amsterdam')::DATE,
      'pharmacies',        (SELECT COALESCE(jsonb_agg(p.name ORDER BY p.name), '[]'::jsonb)
                            FROM public.shift_pharmacies sp
                            JOIN public.pharmacies p ON p.id = sp.pharmacy_id
                            WHERE sp.shift_id = v_dec.shift_id)
    ));

  RETURN true;
END;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 3. declaration_reminder_record — de uitkomst van de SMS.
--
--    Let op wat deze status wél en niet zegt. Hij gaat over de SMS: die is de
--    por, en de enige stap die tijdens de run kan mislukken. De mail heeft zijn
--    eigen status in mail_outbox en loopt langs send-shift-mail.
--
--    Een koerier zonder telefoonnummer eindigt hier daarom op 'failed' met de
--    reden erbij, terwijl zijn mail wél uitgaat. Dat is geen boekhoudfout maar de
--    bedoeling: zo staat de ontbrekende gegevensinvoer zwart-op-wit in een tabel
--    waar de planner bij kan, in plaats van alleen in een logregel die niemand
--    leest.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.declaration_reminder_record(
  p_declaration_id UUID,
  p_stage          SMALLINT,
  p_ok             BOOLEAN,
  p_message_id     TEXT DEFAULT NULL,
  p_error          TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $fn$
  UPDATE public.declaration_reminders
     SET status              = CASE WHEN p_ok THEN 'sent' ELSE 'failed' END,
         sent_at             = CASE WHEN p_ok THEN now() END,
         provider_message_id = p_message_id,
         error               = p_error
   WHERE declaration_id = p_declaration_id
     AND stage          = p_stage;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 4. Rechten — deze drie zijn uitsluitend voor de job.
--    EXECUTE staat standaard aan voor PUBLIC; dat moet er expliciet af, anders
--    kan elke ingelogde gebruiker (of de anon-key) via declaration_reminder_due
--    de telefoonnummers uitlezen — die functie omzeilt als SECURITY DEFINER
--    immers RLS.
-- ────────────────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.declaration_reminder_due(INT)              FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.declaration_reminder_claim(UUID, SMALLINT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.declaration_reminder_record(UUID, SMALLINT, BOOLEAN, TEXT, TEXT)
  FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.declaration_reminder_due(INT)              TO service_role;
GRANT EXECUTE ON FUNCTION public.declaration_reminder_claim(UUID, SMALLINT) TO service_role;
GRANT EXECUTE ON FUNCTION public.declaration_reminder_record(UUID, SMALLINT, BOOLEAN, TEXT, TEXT)
  TO service_role;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie
--   1. Wie er nu aan de beurt zou zijn. Leeg is normaal zolang er geen
--      openstaande declaraties zijn waarvan het moment voorbij is. Staat er een
--      regel met GEEN NUMMER, dan is dat een schoonmaakklus, geen storing.
--   2. De momenten per openstaande declaratie, zodat je ziet of de ondergrens op
--      stage 2 doet wat je verwacht — en welke van de twee termen wint.
--   3. Geen EXECUTE voor anon of authenticated op de drie functies.
-- ────────────────────────────────────────────────────────────────────────
SELECT declaration_id, stage, courier_name,
       CASE WHEN phone_e164 IS NULL THEN 'GEEN NUMMER' ELSE 'ok' END AS nummer,
       shift_date, due_at, expires_at
FROM public.declaration_reminder_due()
ORDER BY due_at;

WITH m AS (
  SELECT d.id,
         public.declaration_shift_end(s.shift_date, s.start_time, s.budgeted_end_time) AS afloop,
         d.token_expires_at AS verloopt,
         c.expected_within_hours AS termijn_uur
  FROM public.shift_declarations d
  JOIN public.shifts s ON s.id = d.shift_id
  CROSS JOIN public.declaration_settings c
  WHERE d.status = 'open' AND d.token_expires_at > now() AND c.id
)
SELECT id, afloop, verloopt,
       afloop + make_interval(mins => termijn_uur * 30)      AS stage1_at,
       afloop + (verloopt - afloop) * 0.8::float8            AS stage2_via_80pct,
       verloopt - INTERVAL '24 hours'                        AS stage2_via_ondergrens,
       LEAST(afloop + (verloopt - afloop) * 0.8::float8,
             verloopt - INTERVAL '24 hours')                 AS stage2_at
FROM m
ORDER BY verloopt
LIMIT 20;

SELECT routine_name, grantee, privilege_type
FROM information_schema.routine_privileges
WHERE routine_schema = 'public'
  AND routine_name LIKE 'declaration_reminder%'
ORDER BY routine_name, grantee;

COMMIT;   -- vervang door ROLLBACK; voor een dry-run zonder op te slaan
