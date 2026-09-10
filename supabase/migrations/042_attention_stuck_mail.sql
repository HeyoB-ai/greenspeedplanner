-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — vastgelopen post zichtbaar maken — 042
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 039 eerst (die zette de vorige kolom in planner_attention).
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien, en draai daarna       │
-- │ supabase/tests/042_attention_stuck_mail_test.sql.                      │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAAROM
--   Een mislukte verzending wordt nooit opnieuw aangeboden. mail_pending_couriers()
--   en mail_claim_for_courier() (migratie 017) pakken alleen 'pending', en de twee
--   functies die iets terugzetten — declaration_release() en mail_release() —
--   filteren op 'sending'. Er is geen pogingenteller. Een 'failed'-rij blijft dus
--   voor altijd staan, en declaration_expire_stale() ruimt hem ook niet op: die
--   raakt alleen 'pending'.
--
--   Datzelfde geldt voor 'expired'. Beide stapelen zich stil op.
--
--   In de gevallen die deze week werkelijk voorkwamen — een dichte MAIL_ALLOWLIST,
--   een koerier zonder adres, een afzenderdomein dat nog niet geverifieerd was —
--   zou automatisch herkansen niets hebben opgelost. Wat ontbrak was dat iemand het
--   zag. Vandaar eerst dit, en de herkansing pas als deze telling laat zien dat er
--   werkelijk 429's en 5xx'en voorkomen. Het voorstel daarvoor staat in de README.
--
-- TWEE TELLERS EN NIET ÉÉN
--   'expired' en 'failed' vragen iets anders van de lezer, en het is juist de
--   VERHOUDING tussen de twee die de oorzaak aanwijst:
--
--     veel expired, geen failed  → er is nooit iets geprobeerd. De poort stond
--                                  dicht, er was geen adres, of de invullink kon
--                                  niet gemaakt worden. Kijk naar de configuratie.
--     geen expired, veel failed  → er is wél geprobeerd en het werd geweigerd.
--                                  Kijk naar mail_outbox.error: Brevo-status,
--                                  netwerkfout, of een bundel zonder inhoud.
--     beide                      → twee verschillende problemen tegelijk.
--
--   Eén samengetelde teller zou precies die verhouding wegpoetsen. De badge kan ze
--   alsnog optellen; de database hoort ze gescheiden aan te bieden. Dezelfde keuze
--   als migratie 034 maakte met betwistingen naast te beoordelen declaraties.
--
-- 'sending' WORDT BEWUST NIET GETELD
--   Tijdens een verzendronde staan er legitiem rijen op 'sending' — dat is de
--   claim, een paar seconden lang. Meetellen zou bij elke run een valse melding
--   geven. Gevolg om te kennen: een rij die PERMANENT op 'sending' blijft staan
--   (het proces stierf tussen claimen en versturen) blijft onzichtbaar. Dat is
--   fail-closed en bewust — er ging niets uit en er gaat niets meer uit — maar het
--   is geen nul.
--
-- WAT ER BEWUST NIET GEBEURT: MEETELLEN IN total
--   Zelfde reden als bij migratie 039. total voedt de badge op Financieel en gaat
--   over werk waar geld aan hangt. Vastgelopen post is een gat in de gegevens.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;


-- ────────────────────────────────────────────────────────────────────────
-- 1. planner_attention — twee kolommen erbij.
--    Een returntype wijzigen kan niet met CREATE OR REPLACE, dus DROP + CREATE +
--    opnieuw GRANT. Derde keer dezelfde ingreep, na 034 en 039.
--
--    is_privileged() staat in ALLE takken: dit is SECURITY DEFINER, dus zonder die
--    voorwaarde zou een koerier de werkvoorraad van de planner kunnen uitlezen — en
--    nu ook hoeveel post er is vastgelopen. Geen exception maar nullen: een badge
--    hoort niets stuk te maken.
-- ────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.planner_attention();

CREATE FUNCTION public.planner_attention()
RETURNS TABLE (
  declarations_to_review  INT,   -- ingediend + betwist
  declarations_disputed   INT,   -- waarvan betwist
  extra_work_to_release   INT,   -- nieuw + betwist
  extra_work_disputed     INT,   -- waarvan betwist
  couriers_without_phone  INT,   -- migratie 039; telt NIET mee in total
  mail_failed             INT,   -- migratie 042; geprobeerd en geweigerd
  mail_expired            INT,   -- migratie 042; nooit geprobeerd, te oud geworden
  total                   INT
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  WITH d AS (
    SELECT count(*) FILTER (WHERE status IN ('submitted', 'disputed'))::INT AS n,
           count(*) FILTER (WHERE status = 'disputed')::INT                 AS betwist
    FROM public.shift_declarations
    WHERE public.is_privileged()
  ), e AS (
    SELECT count(*) FILTER (WHERE status IN ('new', 'disputed'))::INT AS n,
           count(*) FILTER (WHERE status = 'disputed')::INT           AS betwist
    FROM public.extra_work
    WHERE public.is_privileged()
  ), c AS (
    SELECT count(*)::INT AS n
    FROM public.user_profiles up
    LEFT JOIN public.courier_contacts cc ON cc.courier_id = up.id
    WHERE up.role = 'courier'
      AND cc.courier_id IS NULL
      AND public.is_privileged()
  ), m AS (
    -- Eén keer over mail_outbox, twee tellingen. 'sending' valt er bewust buiten:
    -- zie de kop.
    SELECT count(*) FILTER (WHERE status = 'failed')::INT  AS mislukt,
           count(*) FILTER (WHERE status = 'expired')::INT AS verlopen
    FROM public.mail_outbox
    WHERE public.is_privileged()
  )
  SELECT d.n, d.betwist, e.n, e.betwist, c.n, m.mislukt, m.verlopen, d.n + e.n
  FROM d, e, c, m;
$fn$;

REVOKE ALL ON FUNCTION public.planner_attention() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.planner_attention() TO authenticated;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie
--   1. Wat de badges nu zouden tonen. total hoort NIET veranderd te zijn ten
--      opzichte van vóór deze migratie.
--   2. De hele wachtrij per soort en status, zodat de verhouding uit de kop zichtbaar
--      wordt. Hier zie je meteen of het de poort was of de provider.
--   3. De redenen achter de mislukkingen. Dit is de query die bepaalt of de
--      herkansing uit de README de moeite waard is: staan er Brevo 429 of 5xx bij,
--      dan valt er iets te herkansen. Staat er alleen 'niet op MAIL_ALLOWLIST' of
--      een 4xx, dan is herkansen zinloos en moet de configuratie eerst kloppen.
-- ────────────────────────────────────────────────────────────────────────
SELECT * FROM public.planner_attention();

SELECT kind, status, count(*) AS aantal, min(created_at) AS oudste
FROM public.mail_outbox
GROUP BY kind, status
ORDER BY status, kind;

SELECT status,
       COALESCE(left(error, 60), '(geen reden vastgelegd)') AS reden,
       count(*) AS aantal,
       max(created_at) AS laatste
FROM public.mail_outbox
WHERE status IN ('failed', 'expired')
GROUP BY status, COALESCE(left(error, 60), '(geen reden vastgelegd)')
ORDER BY count(*) DESC, status;

COMMIT;   -- vervang door ROLLBACK; voor een dry-run zonder op te slaan
