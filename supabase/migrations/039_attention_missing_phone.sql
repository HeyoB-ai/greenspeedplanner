-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — koeriers zonder telefoonnummer in de badge — 039
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 033 en 034 eerst.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien, en draai daarna       │
-- │ supabase/tests/039_attention_missing_phone_test.sql.                   │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAAROM
--   Gemeten: 3 van de 5 koeriers hebben geen rij in courier_contacts. Dat is geen
--   toeval maar het te verwachten gevolg van een handmatige stap waar niemand aan
--   herinnerd wordt: het nummer wordt nergens in de aanmeldstroom gevraagd. De
--   uitnodiging komt uit de bezorg-app en gaat over een e-mailadres; de
--   registratietrigger (migratie 015) schrijft naam, rol en apotheken. Het enige
--   schrijfpad naar courier_contacts is een planner die het scherm Nummers opent
--   en het nummer intypt.
--
--   Zo'n koerier valt in twee ketens stil weg: sms_due_shifts() (migratie 012)
--   joint met een INNER JOIN op courier_contacts, en de nadeclaratie-herinnering
--   (037) meldt hem wel maar kan geen SMS sturen. In beide gevallen krijgt de
--   koerier niets en ziet niemand het.
--
--   Het contactenscherm waarschuwt er nu voor, maar dat helpt alleen wie dat
--   scherm opent — en dat is precies wat niet gebeurde. Vandaar deze telling: op
--   de plek waar de planning elke sessie langs komt.
--
-- WAT ER BEWUST NIET GEBEURT: MEETELLEN IN total
--   total voedt de badge op Financieel, en dat menu gaat over werk waar geld aan
--   hangt: te beoordelen declaraties en vrij te geven meerwerk. Een ontbrekend
--   telefoonnummer is een gat in de gegevens onder Beheer en hoort daar niet bij
--   op te tellen — dan zou de badge op Financieel een getal tonen waar in dat menu
--   niets aan te doen is. De nieuwe kolom staat er dus naast en total blijft
--   d.n + e.n.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;


-- ────────────────────────────────────────────────────────────────────────
-- 1. planner_attention — één kolom erbij.
--    Een returntype wijzigen kan niet met CREATE OR REPLACE, dus DROP + CREATE +
--    opnieuw GRANT. Zelfde ingreep als migratie 034 deed.
--
--    is_privileged() staat in ALLE takken: dit is SECURITY DEFINER, dus zonder die
--    voorwaarde zou een koerier de werkvoorraad van de planner kunnen uitlezen —
--    en nu ook hoeveel collega's er geen nummer hebben. Geen exception maar
--    nullen: een badge hoort niets stuk te maken.
--
--    Een LEEG nummer bestaat niet en wordt daarom niet geteld: phone_e164 is
--    NOT NULL met een CHECK op E.164 (migratie 011). Staat er een rij, dan staat
--    er een geldig nummer in. "Geen rij" is de enige fouttoestand.
-- ────────────────────────────────────────────────────────────────────────
DROP FUNCTION IF EXISTS public.planner_attention();

CREATE FUNCTION public.planner_attention()
RETURNS TABLE (
  declarations_to_review  INT,   -- ingediend + betwist
  declarations_disputed   INT,   -- waarvan betwist
  extra_work_to_release   INT,   -- nieuw + betwist
  extra_work_disputed     INT,   -- waarvan betwist
  couriers_without_phone  INT,   -- migratie 039; telt NIET mee in total
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
  )
  SELECT d.n, d.betwist, e.n, e.betwist, c.n, d.n + e.n
  FROM d, e, c;
$fn$;

REVOKE ALL ON FUNCTION public.planner_attention() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.planner_attention() TO authenticated;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie
--   1. Wat de badges nu zouden tonen. couriers_without_phone hoort gelijk te zijn
--      aan het aantal uit query 2, en total hoort er NIET in mee te lopen.
--   2. Wie het zijn — dezelfde lijst als het contactenscherm toont.
-- ────────────────────────────────────────────────────────────────────────
SELECT * FROM public.planner_attention();

SELECT up.id AS courier_id, up.name
FROM public.user_profiles up
LEFT JOIN public.courier_contacts cc ON cc.courier_id = up.id
WHERE up.role = 'courier' AND cc.courier_id IS NULL
ORDER BY up.name;

COMMIT;   -- vervang door ROLLBACK; voor een dry-run zonder op te slaan
