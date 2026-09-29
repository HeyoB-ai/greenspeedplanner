-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — de drempel in de selectie, niet in de lus — 052
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 051 eerst; deze migratie gaat uit van duration_minutes().
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien.                       │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAT ER MIS WAS
--   extra_work_sweep() selecteert kandidaten met ORDER BY s.shift_date LIMIT
--   p_limit en toetst de drempel pas daarná, binnen de lus:
--
--     CONTINUE WHEN r.actual - r.planned < v_cfg.extra_work_threshold_minutes;
--
--   Een declaratie die onder de drempel blijft krijgt dus nooit een extra_work-
--   rij. En precies díe rij is waar het NOT EXISTS op kijkt. Zo'n declaratie
--   blijft daardoor voor altijd kandidaat en bezet elk uur opnieuw een plek in
--   die eerste p_limit rijen — de sweep doet er werk aan, besluit "niets aan de
--   hand", en begint een uur later bij dezelfde rij.
--
-- WAAROM DAT ERGER WORDT EN NIET BETER
--   Het aantal declaraties onder de drempel groeit met elke dienst die netjes
--   op tijd klaar was. Dat is de normale gang van zaken, en het is dus een
--   teller die maar één kant op loopt. Zijn het er ooit meer dan p_limit, dan
--   vult die ballast de hele LIMIT en komt de sweep niet meer aan nieuwe
--   declaraties toe.
--
--   Het venijn zit erin dat er dan niets stukgaat. Geen fout, geen volle
--   wachtrij, niets in cron.job_run_details — de sweep draait elk uur keurig en
--   geeft 0 terug. Alleen krijgt geen apotheek nog een goedkeuringsverzoek en
--   verschijnt er geen uitloop meer op een factuur. Dat valt pas op als iemand
--   de omzet mist, en dan is het al maanden aan de gang.
--
--   Op het moment van schrijven zijn het er 2 van de 200. Dit is een migratie
--   voor over een jaar, niet voor vandaag.
--
-- WAT DEZE MIGRATIE DOET
--   De drempelvergelijking gaat van de lus naar de WHERE. Dan telt LIMIT alleen
--   nog rijen die ook werkelijk een extra_work-rij opleveren, en is er geen
--   verschil meer tussen wat de sweep bekijkt en wat hij aanpakt.
--
--   Verder is dit letterlijk de definitie uit 051. De verdeling naar rato, de
--   ON CONFLICT, het overslaan van 'draft' en van shift_type 'urgent' en het
--   returntype blijven zoals ze waren: de functie kiest andere rijen om te
--   bekijken, niet andere rijen om aan te maken.
--
-- BIJVANGST: EEN LEGE invoice_settings
--   Stond er onverhoopt geen rij in invoice_settings, dan was v_cfg NULL en
--   werd "< NULL" nooit waar — de oude vorm belastte dan ALLES door. In de
--   WHERE levert ">= NULL" geen rijen op, dus valt datzelfde geval nu de andere
--   kant op: liever geen verzoek dan een verkeerd verzoek aan een apotheek.
--   Migratie 025 zet die rij neer, dus in de praktijk verandert er niets.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────
-- extra_work_sweep — dezelfde functie, de drempel een lus naar buiten.
--
-- De twee duren staan nu twee keer in de query: als kolom voor de INSERT en als
-- vergelijking in de WHERE. Dat kost niets — duration_minutes() is IMMUTABLE en
-- rekent op twee TIME-waarden — en het alternatief, een subquery of LATERAL om
-- de som één keer op te schrijven, maakt de selectie juist moeilijker te
-- vergelijken met die van declaration_submit(). Die twee horen naast elkaar
-- leesbaar te blijven: lopen ze uiteen, dan wordt een koerier om een toelichting
-- gevraagd die nergens heen gaat.
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
      -- De drempel hoort hier en niet in de lus: alleen zo telt LIMIT rijen die
      -- ook werkelijk iets opleveren. Stond hij eronder, dan bleef elke dienst
      -- die netjes op tijd klaar was kandidaat, en verdrong die op den duur de
      -- diensten die wél een verzoek verdienen.
      AND public.duration_minutes(d.actual_start, d.actual_end)
            - public.duration_minutes(s.start_time, s.budgeted_end_time)
          >= v_cfg.extra_work_threshold_minutes
      AND NOT EXISTS (
        SELECT 1 FROM public.extra_work e
        WHERE e.shift_id = s.id AND e.pharmacy_id = sp.pharmacy_id)
    ORDER BY s.shift_date
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

-- Rechten blijven staan: CREATE OR REPLACE laat de ACL uit 031 ongemoeid en de
-- handtekening is niet veranderd. Een REVOKE/GRANT hier zou alleen herhalen wat
-- er al staat, en verbergen dat er níéts aan de rechten verandert.


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie
-- ────────────────────────────────────────────────────────────────────────

-- Verwacht: false, true — de drempel staat in de selectie, en er is geen
-- CONTINUE meer die hem achteraf alsnog toepast.
SELECT pg_get_functiondef(p.oid) LIKE '%CONTINUE WHEN%'          AS nog_een_continue,
       pg_get_functiondef(p.oid) LIKE '%>= v_cfg.extra_work_threshold_minutes%'
                                                                 AS drempel_in_de_where
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'extra_work_sweep';

-- Het verschil zichtbaar gemaakt. 'bekeek_hij' is wat de sweep vóór deze
-- migratie moest doorlopen voordat hij iets kon aanmaken, 'pakt_hij_nu' is wat
-- hij werkelijk oppakt, en 'ballast' het verschil: declaraties onder de drempel
-- die elk uur opnieuw een plek in de LIMIT bezetten. Loopt 'ballast' op richting
-- p_limit (standaard 200), dan was dit net op tijd.
WITH kandidaat AS (
  SELECT public.duration_minutes(d.actual_start, d.actual_end)
           - public.duration_minutes(s.start_time, s.budgeted_end_time) AS uitloop
  FROM public.shift_declarations d
  JOIN public.shifts s            ON s.id = d.shift_id
  JOIN public.shift_pharmacies sp ON sp.shift_id = s.id
  WHERE d.actual_start IS NOT NULL
    AND d.actual_end   IS NOT NULL
    AND s.budgeted_end_time IS NOT NULL
    AND s.status <> 'draft'
    AND s.shift_type <> 'urgent'
    AND NOT EXISTS (
      SELECT 1 FROM public.extra_work e
      WHERE e.shift_id = s.id AND e.pharmacy_id = sp.pharmacy_id)
)
SELECT count(*)                                                            AS bekeek_hij,
       count(*) FILTER (WHERE k.uitloop >= c.extra_work_threshold_minutes) AS pakt_hij_nu,
       count(*) FILTER (WHERE k.uitloop <  c.extra_work_threshold_minutes) AS ballast,
       c.extra_work_threshold_minutes                                      AS drempel
FROM kandidaat k CROSS JOIN public.invoice_settings c
WHERE c.id
GROUP BY c.extra_work_threshold_minutes;

-- Verwacht: 0 — de functie compileert en draait. Met p_limit 0 selecteert hij
-- niets, dus dit is een proefdraai die geen enkele apotheek post bezorgt.
SELECT public.extra_work_sweep(0) AS meldingen_aangemaakt;

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
