-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — het referentievenster mee naar de apotheek — 054
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 053 eerst; deze migratie bouwt op reference_minutes().
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien.                       │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAT ER MIS WAS: GETALLEN DIE NIET OPTELLEN
--   053 verlegde de maatstaf naar de PDA-tijd, maar twee teksten bleven op de
--   geplande tijd staan. Een BENU-apotheek las daardoor:
--
--     gepland 09:00-09:30 … 23 minuten langer dan gepland
--
--   09:30 plus 23 minuten is 09:53, en de koerier werkte tot 10:08. De twee
--   getallen komen uit twee verschillende werelden: het venster uit de
--   planning, de minuten uit de PDA-tijd (09:00-09:45).
--
--   Dat is niet alleen slordig. Een verzoek om extra tijd dat de ontvanger niet
--   kan NAREKENEN is een verzoek dat ze alleen op goed vertrouwen kan
--   goedkeuren — en precies daarom zette 053 planned_minutes op de referentie.
--   Die winst ging aan de klant voorbij zolang de tekst er niet bij paste.
--
-- WAAROM HET VENSTER IN extra_work HOORT EN NIET IN DE TEKST
--   Het venster wordt bij het aanmaken GEKOPIEERD, net als courier_note
--   (migratie 031). Een koerier die zijn declaratie later corrigeert, of een
--   planner die de dienst verschuift, verandert dan niet met terugwerkende
--   kracht wat er aan de klant is voorgelegd. Zou de mail het venster elke keer
--   opnieuw uit shifts halen, dan kan een apotheek een herinnering krijgen met
--   andere tijden dan het verzoek dat ze eerder las.
--
-- DE GEPLANDE TIJD IS BIJ BENU NIET HAAR ZAAK
--   Bij een selfbilling-filiaal is de PDA-tijd wat BENU zelf registreert en
--   vergoedt. Wat ONZE planning ervan had gemaakt is een interne afspraak; die
--   hoort niet in een verzoek aan de klant. Vandaar dat planned_start en
--   planned_end uit de payload verdwijnen in plaats van dat het venster ernaast
--   komt te staan.
--
-- ÉÉN PLEK WAAR DE KEUZE STAAT
--   reference_window() bepaalt welk venster geldt; reference_minutes() wordt
--   hieronder herschreven tot "de lengte van dat venster". De keuze tussen
--   PDA-tijd en begroting staat daarmee op precies één plek, en het venster en
--   de minuten kunnen niet meer uiteen gaan lopen. Het gedrag van
--   reference_minutes() verandert niet — de verificatie onderaan toont dezelfde
--   vier uitkomsten als 053.
--
-- WAT HIER NIET GEBEURT
--   invoice_lines() blijft ongemoeid. Of BENU op de PDA-tijd gefactureerd moet
--   worden verandert de bedragen, en dat is een aparte beslissing.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────
-- 1. Het venster bij de melding.
--
--    Nullable, om twee redenen. Bestaande rijen worden hieronder bijgevuld,
--    maar niet elke rij is te herleiden (zie punt 7) — en een NOT NULL zou dan
--    de migratie laten klappen op geschiedenis die niemand meer kan repareren.
--    En actual_end is een kopie van de declaratie, die er bij een handmatig
--    aangemaakte rij niet hoeft te zijn.
--
--    actual_end en niet ook actual_start: de apotheek moet kunnen narekenen, en
--    dat kan met het venster, de einduitloop en actual_minutes dat er al staat.
--    Een vierde tijd erbij maakt het verzoek langer zonder dat het meer zegt.
-- ────────────────────────────────────────────────────────────────────────
ALTER TABLE public.extra_work ADD COLUMN IF NOT EXISTS reference_kind  TEXT;
ALTER TABLE public.extra_work ADD COLUMN IF NOT EXISTS reference_start TIME;
ALTER TABLE public.extra_work ADD COLUMN IF NOT EXISTS reference_end   TIME;
ALTER TABLE public.extra_work ADD COLUMN IF NOT EXISTS actual_end      TIME;

ALTER TABLE public.extra_work DROP CONSTRAINT IF EXISTS extra_work_reference_kind_chk;
ALTER TABLE public.extra_work ADD CONSTRAINT extra_work_reference_kind_chk
  CHECK (reference_kind IS NULL OR reference_kind IN ('pda', 'planned'));

COMMENT ON COLUMN public.extra_work.reference_kind IS
  'Waartegen de uitloop gemeten is: ''pda'' (BENU selfbilling) of ''planned''. Kopie bij aanmaken.';
COMMENT ON COLUMN public.extra_work.reference_start IS
  'Begin van het referentievenster. Kopie bij aanmaken, zie reference_kind.';
COMMENT ON COLUMN public.extra_work.reference_end IS
  'Einde van het referentievenster. Kopie bij aanmaken, zie reference_kind.';
COMMENT ON COLUMN public.extra_work.actual_end IS
  'Tot hoe laat er werkelijk gewerkt is. Kopie uit de declaratie bij aanmaken.';


-- ────────────────────────────────────────────────────────────────────────
-- 2. reference_window — welk venster geldt, en hoe het heet.
--
--    Dezelfde volgorde als reference_minutes() in 053: BENU met een PDA-tijd
--    neemt de PDA-tijd, anders de begroting, en is er geen van beide dan is er
--    niets om tegen af te zetten. Die volgorde staat vanaf hier ALLEEN hier;
--    punt 3 maakt reference_minutes() de lengte van wat deze functie teruggeeft.
--
--    Geeft altijd één rij terug, ook als er geen venster is — drie NULLs. Een
--    functie die soms nul rijen geeft verandert een LATERAL join stilletjes in
--    een filter, en dan verdwijnen er meldingen uit de sweep zonder dat iemand
--    het ziet.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.reference_window(
  p_is_benu    BOOLEAN,
  p_pda_start  TIME, p_pda_end  TIME,
  p_plan_start TIME, p_plan_end TIME
)
RETURNS TABLE (kind TEXT, win_start TIME, win_end TIME)
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT CASE WHEN q.heeft_pda THEN 'pda' WHEN q.heeft_plan THEN 'planned' END,
         CASE WHEN q.heeft_pda THEN p_pda_start WHEN q.heeft_plan THEN p_plan_start END,
         CASE WHEN q.heeft_pda THEN p_pda_end   WHEN q.heeft_plan THEN p_plan_end   END
  FROM (SELECT COALESCE(p_is_benu, false)
               AND p_pda_start IS NOT NULL AND p_pda_end IS NOT NULL AS heeft_pda,
               p_plan_end IS NOT NULL                                AS heeft_plan) q;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 3. reference_minutes — nu de lengte van dat venster.
--
--    Zelfde handtekening, zelfde uitkomsten, alleen niet langer een tweede
--    plek waar de keuze staat opgeschreven. Dat is de hele wijziging: de
--    verificatie onderaan draait de vier gevallen uit 053 nog een keer.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.reference_minutes(
  p_is_benu    BOOLEAN,
  p_pda_start  TIME, p_pda_end  TIME,
  p_plan_start TIME, p_plan_end TIME
)
RETURNS INT
LANGUAGE sql IMMUTABLE AS $fn$
  SELECT public.duration_minutes(w.win_start, w.win_end)
  FROM public.reference_window(p_is_benu, p_pda_start, p_pda_end, p_plan_start, p_plan_end) w;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 4. extra_work_sweep — het venster mee naar binnen.
--
--    De definitie uit 053, met het venster uit een LATERAL erbij. planned is
--    de lengte van datzelfde venster; sinds punt 3 is dat letterlijk wat
--    reference_minutes() rekent, dus het is dezelfde som en geen tweede.
--
--    declaration_is_benu() wordt nu één keer per rij aangeroepen in plaats van
--    binnen in reference_minutes(): het antwoord is ook nodig om het venster te
--    benoemen, en twee aanroepen zouden bij een gewijzigde dienst uit elkaar
--    kunnen lopen.
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
             d.id AS declaration_id, d.courier_note, d.actual_end,
             w.kind      AS ref_kind,
             w.win_start AS ref_start,
             w.win_end   AS ref_end,
             public.duration_minutes(w.win_start, w.win_end)        AS planned,
             public.duration_minutes(d.actual_start, d.actual_end)  AS actual,
             (SELECT count(*) FROM public.shift_pharmacies x WHERE x.shift_id = s.id) AS n_pharmacies,
             (SELECT sum(x.budgeted_minutes) FROM public.shift_pharmacies x WHERE x.shift_id = s.id) AS sum_minutes,
             EXISTS (SELECT 1 FROM public.shift_pharmacies x
                      WHERE x.shift_id = s.id AND x.budgeted_minutes IS NULL) AS any_missing,
             sp.budgeted_minutes
      FROM public.shift_declarations d
      JOIN public.shifts s            ON s.id = d.shift_id
      JOIN public.shift_pharmacies sp ON sp.shift_id = s.id
      CROSS JOIN LATERAL public.reference_window(
        public.declaration_is_benu(s.id),
        d.pda_start, d.pda_end, s.start_time, s.budgeted_end_time) w
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
      extra_minutes, share_pct, share_minutes, courier_note,
      reference_kind, reference_start, reference_end, actual_end)
    VALUES (
      r.shift_id, r.pharmacy_id, r.declaration_id, r.planned, r.actual,
      r.actual - r.planned, round(v_share * 100, 1),
      round((r.actual - r.planned) * v_share, 1), r.courier_note,
      r.ref_kind, r.ref_start, r.ref_end, r.actual_end)
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
-- 5. extra_work_release — het venster in de payload.
--
--    De definitie uit migratie 032, met planned_start en planned_end eruit en
--    het referentievenster ervoor in de plaats. Die twee kwamen uit shifts en
--    waren juist de bron van de verkeerde tijden; ze staan daarom niet naast
--    het venster maar in plaats daarvan.
--
--    Ze komen uit extra_work en niet uit shifts: het is de KOPIE van het moment
--    van aanmaken die aan de klant is voorgelegd. Zie de kop van deze migratie.
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
  v_chain public.groups;
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
  v_chain := public.pharmacy_chain(v_row.pharmacy_id);

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

  INSERT INTO public.mail_outbox (
    courier_id, recipient_override, kind, subject_type, subject_id, payload)
  VALUES (
    NULL, v_email, 'extra_work_request', 'shift', v_row.shift_id,
    jsonb_build_object(
      'extra_work_id',   v_row.id,
      'pharmacy_name',   (SELECT name FROM public.pharmacies WHERE id = v_row.pharmacy_id),
      'shift_date',      v_shift.shift_date,
      'weekday',         EXTRACT(ISODOW FROM v_shift.shift_date),
      -- Het venster waartegen gemeten is, met de soort erbij zodat de mail hem
      -- bij de juiste naam kan noemen. Zonder die soort staat er "gepland" boven
      -- een PDA-tijd, en dat is precies wat deze migratie herstelt.
      'reference_kind',  v_row.reference_kind,
      'reference_start', to_char(v_row.reference_start, 'HH24:MI'),
      'reference_end',   to_char(v_row.reference_end,   'HH24:MI'),
      'actual_end',      to_char(v_row.actual_end,      'HH24:MI'),
      'extra_minutes',   v_row.share_minutes,
      'respond_hours',   v_cfg.extra_work_respond_hours,
      -- Alleen bij een gesplitste keten: dan komt déze tijd op de eigen factuur
      -- van het filiaal en niet op die van de keten.
      'own_invoice',     COALESCE(v_chain.split_extra_work, false),
      'note',            v_note));
END;
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 6. extra_work_by_token en extra_work_overview — het venster naar de schermen.
--    DROP en CREATE, want het returntype verandert.
--
--    Ook het plannerscherm krijgt reference_kind mee. Dat scherm zette
--    "45 min gepland, 68 min werkelijk" boven een melding die tegen de PDA-tijd
--    gemeten was: dezelfde fout als in de mail, alleen voor eigen mensen.
-- ────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.extra_work_by_token(TEXT);

CREATE FUNCTION public.extra_work_by_token(p_token TEXT)
RETURNS TABLE (
  extra_work_id   UUID,
  status          TEXT,
  pharmacy_name   TEXT,
  shift_date      DATE,
  reference_kind  TEXT,
  reference_start TEXT,
  reference_end   TEXT,
  actual_end      TEXT,
  extra_minutes   NUMERIC,
  note            TEXT,
  respond_by      TIMESTAMPTZ,
  responded_at    TIMESTAMPTZ,
  response_note   TEXT
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT e.id, e.status, p.name,
         s.shift_date,
         e.reference_kind,
         to_char(e.reference_start, 'HH24:MI'),
         to_char(e.reference_end,   'HH24:MI'),
         to_char(e.actual_end,      'HH24:MI'),
         e.share_minutes,
         COALESCE(e.planner_note, e.courier_note),
         e.respond_by, e.responded_at, e.response_note
  FROM public.extra_work e
  JOIN public.shifts s     ON s.id = e.shift_id
  JOIN public.pharmacies p ON p.id = e.pharmacy_id
  WHERE e.token_hash = public.declaration_hash_token(p_token)
    AND e.token_expires_at > now();
$fn$;

DROP FUNCTION IF EXISTS public.extra_work_overview(DATE, DATE);

CREATE FUNCTION public.extra_work_overview(
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
  reference_kind  TEXT,
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
         e.reference_kind,
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


-- ────────────────────────────────────────────────────────────────────────
-- 7. Bestaande meldingen bijvullen.
--
--    Niet gokken maar HERLEIDEN: planned_minutes staat er al, en die is ooit
--    tegen één van twee vensters gerekend. Past hij op de PDA-tijd, dan is de
--    PDA-tijd het venster; past hij op de begroting, dan die. Rijen van vóór
--    053 komen zo vanzelf op de begroting uit — daar bestond de andere keuze
--    nog niet.
--
--    Past hij op geen van beide, dan blijft de rij leeg. Dat gebeurt als de
--    dienst na het aanmaken van de melding is verschoven, en dan is elk venster
--    dat we hier zouden invullen een verzinsel dat de apotheek niet kan
--    narekenen. Liever geen venster dan een venster dat niet klopt: mail en
--    pagina laten die regel dan weg en tonen alleen het aantal minuten.
--
--    De PDA-tijd gaat voor wanneer beide passen. Dat is de stand sinds 053, en
--    het verschil doet zich alleen voor als de twee vensters even lang zijn.
-- ────────────────────────────────────────────────────────────────────────
WITH bron AS (
  SELECT e.id,
         e.planned_minutes,
         d.actual_end,
         w.kind      AS pda_kind,
         w.win_start AS pda_start,
         w.win_end   AS pda_end,
         public.duration_minutes(w.win_start, w.win_end)              AS pda_minuten,
         s.start_time                                                  AS plan_start,
         s.budgeted_end_time                                           AS plan_end,
         public.duration_minutes(s.start_time, s.budgeted_end_time)    AS plan_minuten
  FROM public.extra_work e
  JOIN public.shifts s ON s.id = e.shift_id
  LEFT JOIN public.shift_declarations d ON d.id = e.declaration_id
  CROSS JOIN LATERAL public.reference_window(
    public.declaration_is_benu(s.id),
    d.pda_start, d.pda_end, s.start_time, s.budgeted_end_time) w
  WHERE e.reference_kind IS NULL
)
UPDATE public.extra_work e SET
  actual_end = b.actual_end,
  reference_kind = CASE
    WHEN b.pda_kind = 'pda' AND b.planned_minutes = b.pda_minuten  THEN 'pda'
    WHEN b.plan_end IS NOT NULL AND b.planned_minutes = b.plan_minuten THEN 'planned'
  END,
  reference_start = CASE
    WHEN b.pda_kind = 'pda' AND b.planned_minutes = b.pda_minuten  THEN b.pda_start
    WHEN b.plan_end IS NOT NULL AND b.planned_minutes = b.plan_minuten THEN b.plan_start
  END,
  reference_end = CASE
    WHEN b.pda_kind = 'pda' AND b.planned_minutes = b.pda_minuten  THEN b.pda_end
    WHEN b.plan_end IS NOT NULL AND b.planned_minutes = b.plan_minuten THEN b.plan_end
  END
FROM bron b
WHERE b.id = e.id;


-- ────────────────────────────────────────────────────────────────────────
-- 8. Rechten. reference_window is nieuw; de twee opnieuw aangemaakte functies
--    zijn hun ACL kwijtgeraakt door de DROP.
-- ────────────────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.reference_window(BOOLEAN, TIME, TIME, TIME, TIME)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reference_window(BOOLEAN, TIME, TIME, TIME, TIME)
  TO service_role;

REVOKE ALL     ON FUNCTION public.extra_work_by_token(TEXT)       FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.extra_work_by_token(TEXT)       TO service_role;

REVOKE ALL     ON FUNCTION public.extra_work_overview(DATE, DATE) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.extra_work_overview(DATE, DATE) TO authenticated, service_role;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie
-- ────────────────────────────────────────────────────────────────────────

-- Verwacht: 45 / 30 / 30 / NULL — dezelfde vier als in 053. reference_minutes()
-- is herschreven, maar mag zich niet anders gedragen.
SELECT public.reference_minutes(true,  TIME '09:00', TIME '09:45', TIME '09:00', TIME '09:30') AS benu_met_pda,
       public.reference_minutes(false, NULL,         NULL,         TIME '09:00', TIME '09:30') AS gewone_apotheek,
       public.reference_minutes(true,  NULL,         NULL,         TIME '09:00', TIME '09:30') AS benu_zonder_pda,
       public.reference_minutes(false, NULL,         NULL,         TIME '09:00', NULL)         AS geen_referentie;

-- Verwacht: pda 09:00-09:45 / planned 09:00-09:30 / planned 09:00-09:30 / NULL.
-- Het venster hoort dezelfde keuze te maken als de minuten hierboven.
SELECT * FROM public.reference_window(true,  TIME '09:00', TIME '09:45', TIME '09:00', TIME '09:30');
SELECT * FROM public.reference_window(false, NULL,         NULL,         TIME '09:00', TIME '09:30');
SELECT * FROM public.reference_window(true,  NULL,         NULL,         TIME '09:00', TIME '09:30');
SELECT * FROM public.reference_window(false, NULL,         NULL,         TIME '09:00', NULL);

-- Hoe de bestaande meldingen zijn bijgevuld. Verwacht: geen rij met
-- reference_kind NULL, of anders een handjevol waarvan de dienst na het
-- aanmaken is verschoven — die tonen straks alleen het aantal minuten.
SELECT COALESCE(reference_kind, 'niet te herleiden') AS venster, count(*)
FROM public.extra_work
GROUP BY 1 ORDER BY 1;

-- Telt het weer op? Verwacht: geen rijen. Per melding hoort de lengte van het
-- venster gelijk te zijn aan planned_minutes; is dat niet zo, dan leest de
-- apotheek opnieuw twee getallen uit twee werelden.
SELECT id, reference_kind, reference_start, reference_end, planned_minutes,
       public.duration_minutes(reference_start, reference_end) AS venster_minuten
FROM public.extra_work
WHERE reference_kind IS NOT NULL
  AND public.duration_minutes(reference_start, reference_end) IS DISTINCT FROM planned_minutes;

-- Verwacht: true, false — de payload draagt het venster en niet meer de
-- geplande tijden van de dienst.
SELECT pg_get_functiondef(p.oid) LIKE '%reference_start%' AS payload_heeft_venster,
       pg_get_functiondef(p.oid) LIKE '%planned_start%'   AS payload_heeft_nog_gepland
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'extra_work_release';

-- Verwacht: 0 — de sweep compileert en draait, en met limiet 0 gaat er niets uit.
SELECT public.extra_work_sweep(0) AS meldingen_aangemaakt;

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
