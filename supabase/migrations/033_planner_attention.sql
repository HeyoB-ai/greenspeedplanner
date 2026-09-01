-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — telling voor de badge op het menu Financieel — 033
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 031 eerst (die maakt extra_work aan).
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien, en draai daarna       │
-- │ supabase/tests/033_planner_attention_test.sql.                         │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAAROM
--   De menubalk gaat van tien losse knoppen naar twee uitklapmenu's. Dat is
--   winst voor de balk, maar verlies voor wat er ONDER die menu's ligt: een
--   ingediende declaratie of een meerwerkmelding verdwijnt achter een klik en
--   ziet niemand meer. De telbadge op Financieel is wat dat compenseert.
--
-- WAT ER GETELD WORDT — alleen wat op de planner wacht
--   • shift_declarations met status 'submitted'
--       De koerier heeft ingevuld; het ligt nu bij de planner. Status 'open'
--       telt NIET mee: daar wachten we op de koerier, en dan is de badge geen
--       werkvoorraad meer maar een gestaag oplopend getal dat niemand leest.
--   • extra_work met status 'new'
--       Nog niet vrijgegeven, dus nog niet bij de apotheek. 'released' telt
--       niet mee (die ligt bij de klant) en 'expired' evenmin — die is na 48
--       uur zonder reactie gewoon factureerbaar en vraagt niets.
--
-- Bewust NIET meegeteld: betwist meerwerk. Dat vraagt wél iets van de planner,
-- maar het hoort in het rijtje "afgehandeld door de klant" en niet in een
-- werkvoorraadteller. Wil je het er toch bij, dan is dat één regel hieronder.
--
-- Eén functie in plaats van twee overzichten: de badge staat op elk scherm en
-- laadt bij elke verversing. Twee volledige overzichten ophalen om er twee
-- getallen uit te tellen is verkeerd om.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.planner_attention()
RETURNS TABLE (
  declarations_to_review  INT,
  extra_work_to_release   INT,
  total                   INT
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  -- is_privileged() staat in beide takken: dit is SECURITY DEFINER, dus zonder
  -- die voorwaarde zou een koerier de werkvoorraad van de planner kunnen
  -- uitlezen. Geen exception maar nullen — een badge hoort niets stuk te maken.
  WITH d AS (
    SELECT count(*)::INT AS n
    FROM public.shift_declarations
    WHERE status = 'submitted' AND public.is_privileged()
  ), e AS (
    SELECT count(*)::INT AS n
    FROM public.extra_work
    WHERE status = 'new' AND public.is_privileged()
  )
  SELECT d.n, e.n, d.n + e.n FROM d, e;
$fn$;

REVOKE ALL ON FUNCTION public.planner_attention() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.planner_attention() TO authenticated;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie
--   1. Wat de badge nu zou tonen.
--   2. De verdeling per status, zodat je kunt zien of het klopt met wat er in
--      de schermen staat — en wat er bewust buiten de telling valt.
-- ────────────────────────────────────────────────────────────────────────
SELECT * FROM public.planner_attention();

SELECT 'declaratie' AS soort, status, count(*) FROM public.shift_declarations GROUP BY status
UNION ALL
SELECT 'meerwerk', status, count(*) FROM public.extra_work GROUP BY status
ORDER BY 1, 2;

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
