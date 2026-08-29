-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — nadeclaratie: de link opent ook na beoordeling — 023
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 018 t/m 022 eerst.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien, en draai daarna       │
-- │ supabase/tests/023_declaration_by_token_review_test.sql.               │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAT ER VERANDERT
--   declaration_by_token() gaf alleen rijen terug met status 'open' of
--   'submitted'. Een koerier die zijn link opende nadat de planning had
--   goedgekeurd of betwist, kreeg daardoor het scherm "deze link werkt niet
--   meer" — terwijl de link prima werkt en er iets te lezen valt. De vier
--   meldingen uit migratie 022 kwamen zo in de praktijk nooit in beeld: je komt
--   niet eens aan opslaan toe.
--
--   Voortaan komen 'approved' en 'disputed' ook terug, met review_note erbij, en
--   bepaalt de pagina wat ze toont: een leesweergave in plaats van een formulier.
--
-- WAT NIET VERANDERT
--   * Een VERLOPEN token blijft afgewezen: dan is de link op, ongeacht de status.
--   * Een ONBEKEND token blijft nul rijen geven, zonder enig onderscheid.
--   * declaration_submit() houdt de meldingen uit 022. Die blijven nodig voor het
--     geval dat de planning goedkeurt terwijl het formulier openstaat — de pagina
--     is dan al geladen en loopt pas bij het opslaan tegen de status aan.
--
-- WAAROM OPNIEUW NEERZETTEN
--   Er komt een kolom bij (review_note) en CREATE OR REPLACE kan het returntype
--   niet wijzigen. Dus DROP en CREATE, en daarna de rechten opnieuw — die
--   verdwijnen met de functie. Alles in één transactie.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

DROP FUNCTION IF EXISTS public.declaration_by_token(TEXT);

CREATE FUNCTION public.declaration_by_token(p_token TEXT)
RETURNS TABLE (
  declaration_id    UUID,
  status            TEXT,
  courier_name      TEXT,
  shift_date        DATE,
  start_time        TEXT,
  budgeted_end_time TEXT,
  transport_mode    TEXT,
  own_car           BOOLEAN,
  pharmacies        JSONB,
  actual_start      TEXT,
  actual_end        TEXT,
  claims_travel     BOOLEAN,
  own_car_km        NUMERIC,
  courier_note      TEXT,
  submitted_at      TIMESTAMPTZ,
  -- Nieuw: waarom de planning betwist heeft. Bij een goedgekeurde declaratie
  -- meestal leeg; bij een betwiste is dit het enige wat de koerier verder helpt.
  review_note       TEXT
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT d.id, d.status, up.name,
         s.shift_date,
         to_char(s.start_time, 'HH24:MI'),
         to_char(s.budgeted_end_time, 'HH24:MI'),
         s.transport_mode,
         s.transport_mode = 'car' AND s.car_is_own IS TRUE,
         (SELECT COALESCE(jsonb_agg(p.name ORDER BY p.name), '[]'::jsonb)
          FROM public.shift_pharmacies sp
          JOIN public.pharmacies p ON p.id = sp.pharmacy_id
          WHERE sp.shift_id = s.id),
         to_char(d.actual_start, 'HH24:MI'),
         to_char(d.actual_end,   'HH24:MI'),
         d.claims_travel, d.own_car_km, d.courier_note, d.submitted_at,
         d.review_note
  FROM public.shift_declarations d
  JOIN public.shifts s         ON s.id  = d.shift_id
  JOIN public.user_profiles up ON up.id = d.courier_id
  WHERE d.token_hash = public.declaration_hash_token(p_token)
    AND d.token_expires_at > now();
  -- Geen statusfilter meer. Wat er met de rij gedaan mag worden is een vraag voor
  -- declaration_submit(); wat er getoond mag worden is deze. Die twee liepen door
  -- elkaar en dat maakte "al beoordeeld" niet te onderscheiden van "kapotte link".
$$;

REVOKE ALL     ON FUNCTION public.declaration_by_token(TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.declaration_by_token(TEXT) TO service_role;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie — de kolom review_note zit in het resultaat, en er staat geen
-- statusfilter meer in de definitie.
-- ────────────────────────────────────────────────────────────────────────
SELECT pg_get_function_result(p.oid) LIKE '%review_note%'              AS heeft_review_note,
       pg_get_functiondef(p.oid)     NOT LIKE '%d.status IN%'          AS geen_statusfilter
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'declaration_by_token';

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
