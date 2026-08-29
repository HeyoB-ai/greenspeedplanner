-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — nadeclaratie: zeggen wat er aan de hand is — 022
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 018 t/m 021 eerst. Deze migratie vervangt uitsluitend de body
-- van declaration_submit(); signatuur en returntype blijven gelijk.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien, en draai daarna       │
-- │ supabase/tests/022_declaration_submit_reasons_test.sql.                │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAT ER VERANDERT
--   Indienen dat niet lukt gaf altijd dezelfde melding: "Deze link is niet
--   (meer) geldig." Daar zitten drie verschillende dingen onder, en bij twee
--   ervan is die melding onwaar — de link wérkt, de koerier mag alleen niet meer
--   opslaan omdat de planning er al naar gekeken heeft. Iemand die dat leest
--   denkt dat er iets stuk is en belt, of doet niets meer.
--
--   Voortaan per geval een eigen melding, en een eigen SQLSTATE zodat de
--   invulpagina het verschil kan zien tussen "deze link doet niets" en "deze
--   opgave staat vast".
--
-- WAAROM DE OPZOEKING IN TWEEEN GAAT
--   De oude query zocht op token_hash ÉN status ÉN vervaldatum tegelijk. Nul
--   rijen betekende dan drie dingen tegelijk, en daar valt geen passende melding
--   uit af te leiden. Nu eerst zoeken op ALLEEN de hash, en daarna beoordelen.
--
--   Dat is precies de plek om op te letten: een onbekend token moet dezelfde
--   nietszeggende melding houden. Anders wordt deze functie een orakel dat op
--   elk gegokt token antwoordt of het bestaat. De extra informatie komt pas
--   beschikbaar nádat is vastgesteld dat de aanvrager een geldig token in handen
--   heeft — en wie dat heeft, mag weten hoe zijn eigen declaratie ervoor staat.
--
-- VOLGORDE VAN DE CONTROLES
--   approved → disputed → verlopen. Een goedgekeurde declaratie is definitief,
--   ook als de link intussen verlopen is; "verlopen" zou daar het minst nuttige
--   van de twee ware antwoorden zijn.
--
-- SQLSTATE-CODES
--   28000  onbekend token — de generieke melding (ongewijzigd)
--   45001  link verlopen
--   45002  in behandeling bij de planning (disputed)
--   45003  al goedgekeurd
--   Klasse 45 is vrij: Postgres gebruikt hem zelf niet. De Edge Function
--   herkent 45xxx als "geldig token, maar afgesloten" en toont de melding.
--
-- declaration_review() en declaration_compute() blijven ONGEMOEID.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.declaration_submit(
  p_token         TEXT,
  p_actual_start  TIME,
  p_actual_end    TIME,
  p_claims_travel BOOLEAN,
  p_own_car_km    NUMERIC DEFAULT NULL,
  p_note          TEXT    DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_dec     public.shift_declarations;
  v_own_car BOOLEAN;
  v_km      NUMERIC;
BEGIN
  -- Stap 1: alleen op de hash. Geen status- en geen vervalfilter, anders is
  -- "onbekend" niet te onderscheiden van "bestaat wel, mag niet meer".
  SELECT d.* INTO v_dec
  FROM public.shift_declarations d
  WHERE d.token_hash = public.declaration_hash_token(p_token);

  -- Stap 2: onbekend token houdt de nietszeggende melding. Hier mag niets
  -- uitlekken over wat er wél bestaat.
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Deze link is niet (meer) geldig.' USING ERRCODE = '28000';
  END IF;

  -- Stap 3: het token is geldig, dus de houder mag weten hoe zijn eigen
  -- declaratie ervoor staat.
  IF v_dec.status = 'approved' THEN
    RAISE EXCEPTION 'Deze declaratie is al goedgekeurd en kan niet meer worden aangepast.'
      USING ERRCODE = '45003';
  ELSIF v_dec.status = 'disputed' THEN
    RAISE EXCEPTION 'De planning kijkt hier nog naar. Neem contact op om iets te wijzigen.'
      USING ERRCODE = '45002';
  ELSIF v_dec.token_expires_at <= now() THEN
    RAISE EXCEPTION 'Deze link is verlopen. Neem contact op met de planning.'
      USING ERRCODE = '45001';
  END IF;

  -- ── Vanaf hier ongewijzigd ten opzichte van migratie 019 ───────────────
  IF p_actual_start IS NULL OR p_actual_end IS NULL THEN
    RAISE EXCEPTION 'Vul zowel de begintijd als de eindtijd in.';
  END IF;

  SELECT s.transport_mode = 'car' AND s.car_is_own IS TRUE INTO v_own_car
  FROM public.shifts s WHERE s.id = v_dec.shift_id;

  -- Kilometers alleen bij een eigen auto én een claim.
  v_km := CASE WHEN p_claims_travel IS TRUE AND v_own_car THEN p_own_car_km END;

  IF p_claims_travel IS TRUE AND v_own_car AND (v_km IS NULL OR v_km <= 0) THEN
    RAISE EXCEPTION 'Vul het aantal gereden kilometers in.';
  END IF;

  UPDATE public.shift_declarations
     SET actual_start  = p_actual_start,
         actual_end    = p_actual_end,
         claims_travel = COALESCE(p_claims_travel, false),
         own_car_km    = v_km,
         courier_note  = NULLIF(btrim(COALESCE(p_note, '')), ''),
         status        = 'submitted',
         submitted_at  = now()
   WHERE id = v_dec.id;

  PERFORM public.declaration_recompute(v_dec.id);
  RETURN v_dec.id;
END;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- Rechten. CREATE OR REPLACE laat de bestaande ACL staan; dit is een herhaling
-- van migratie 019, zodat dit bestand op zichzelf klopt.
-- ────────────────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.declaration_submit(TEXT, TIME, TIME, BOOLEAN, NUMERIC, TEXT)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.declaration_submit(TEXT, TIME, TIME, BOOLEAN, NUMERIC, TEXT)
  TO service_role;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie — een onbekend token hoort nog steeds de generieke melding te
-- geven, met SQLSTATE 28000 en zonder iets prijs te geven.
-- ────────────────────────────────────────────────────────────────────────
DO $$
DECLARE v_state TEXT; v_msg TEXT;
BEGIN
  BEGIN
    PERFORM public.declaration_submit('dit-token-bestaat-niet', TIME '08:00', TIME '12:00', false);
    RAISE EXCEPTION 'VERIFICATIE GEFAALD: een onbekend token werd geaccepteerd.';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_state <> '28000' THEN
      RAISE EXCEPTION 'VERIFICATIE GEFAALD: onbekend token gaf SQLSTATE % (%).', v_state, v_msg;
    END IF;
    RAISE NOTICE 'Verificatie geslaagd: onbekend token geeft 28000 met "%".', v_msg;
  END;
END $$;

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
