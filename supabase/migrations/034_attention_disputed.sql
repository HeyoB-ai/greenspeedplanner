-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — betwistingen meetellen in de badge — 034
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 033 eerst.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien, en draai daarna       │
-- │ supabase/tests/034_attention_disputed_test.sql.                        │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAAROM
--   033 telde alleen 'submitted' en 'new'. Een betwisting bleef daardoor
--   onzichtbaar, terwijl dat de meest urgente categorie in het systeem is: er
--   staat geld open bij iemand die het er niet mee eens is, en dat lost zichzelf
--   nooit op. Beide soorten tellen nu mee.
--
-- TWEE SOORTEN BETWISTING, ALLEBEI EEN OPEN LUS
--   • meerwerk 'disputed'    — gezet door de APOTHEEK. Het meerwerk gaat niet
--                              op de factuur; de koerier krijgt het wel betaald.
--                              Er ligt dus een verschil dat iemand moet oppakken.
--   • declaratie 'disputed'  — gezet door de PLANNER zelf, met declaration_review
--                              ('dispute'). De status blijft staan tot hij hem
--                              alsnog goedkeurt of heropent. Dat is precies wat
--                              de badge zichtbaar moet houden: iets waar de
--                              planner het niet mee eens was en dat daarna bleef
--                              liggen. Gevolg om te kennen: de badge gaat niet
--                              op nul zolang er een betwisting openstaat, en dat
--                              is de bedoeling.
--
-- Betwist telt apart mee terug, zodat het scherm kan laten zien dat het niet om
-- gewone werkvoorraad gaat. De teruggeefwaarde verandert daarmee van vorm; dat
-- kan niet met CREATE OR REPLACE, vandaar DROP + CREATE + opnieuw GRANT.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

DROP FUNCTION IF EXISTS public.planner_attention();

CREATE FUNCTION public.planner_attention()
RETURNS TABLE (
  declarations_to_review  INT,   -- ingediend + betwist
  declarations_disputed   INT,   -- waarvan betwist
  extra_work_to_release   INT,   -- nieuw + betwist
  extra_work_disputed     INT,   -- waarvan betwist
  total                   INT
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  -- is_privileged() staat in beide takken: dit is SECURITY DEFINER, dus zonder
  -- die voorwaarde zou een koerier de werkvoorraad van de planner kunnen
  -- uitlezen. Geen exception maar nullen — een badge hoort niets stuk te maken.
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
  )
  SELECT d.n, d.betwist, e.n, e.betwist, d.n + e.n FROM d, e;
$fn$;

REVOKE ALL ON FUNCTION public.planner_attention() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.planner_attention() TO authenticated;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie
--   1. Wat de badge nu zou tonen.
--   2. De verdeling per status. 'open' (wacht op de koerier), 'released'
--      (wacht op de apotheek) en 'expired' (factureerbaar) horen er niet in.
-- ────────────────────────────────────────────────────────────────────────
SELECT * FROM public.planner_attention();

SELECT 'declaratie' AS soort, status, count(*) FROM public.shift_declarations GROUP BY status
UNION ALL
SELECT 'meerwerk', status, count(*) FROM public.extra_work GROUP BY status
ORDER BY 1, 2;

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
