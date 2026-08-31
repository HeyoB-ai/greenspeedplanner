-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — declaration_compute: cast op de vaste zinnen — 027
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 020 (en 026) eerst.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien, en draai daarna       │
-- │ supabase/tests/027_declaration_compute_cast_test.sql.                  │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- ALLEEN EEN CAST, GEEN GEDRAGSWIJZIGING
--   Dit is de body van migratie 020, letterlijk overgenomen, met op drie regels
--   een ::TEXT erbij. Verder is er niets veranderd — geen tak, geen tekst, geen
--   volgorde. De regels in kwestie:
--
--     'de dienst heeft geen apotheek'
--     'geen afstand bekend voor deze koerier en apotheek'
--     'koerier heeft geen standplaats'
--
-- WAAROM
--   Voor `text[] || <letterlijke tekst>` heeft Postgres twee kandidaten:
--
--     anyarray || anyelement   → array met een element erbij
--     anyarray || anyarray     → twee arrays aan elkaar
--
--   Een letterlijke 'tekst' heeft type `unknown` en past op allebei. Kiest
--   Postgres de tweede, dan leest hij de zin als ARRAY-literaal — daar horen
--   accolades bij — en volgt "malformed array literal". Niet bij het aanmaken
--   van de functie maar tijdens de uitvoering, en dus alleen op het moment dat
--   zo'n tak zich voordoet.
--
--   Dat is precies wat er bij invoice_lines() gebeurde (migratie 026). Daar was
--   het zichtbaar omdat die takken zich meteen voordeden; hier gaat het om drie
--   gevallen die zich in de huidige gegevens nog niet hebben voorgedaan: een
--   koerier zonder standplaats, een onbekende afstand, en een dienst zonder
--   apotheek. Alle drie zijn het juist de gevallen die de planner moet zien.
--
--   De regels met format(…) hadden er geen last van: die geven een getypeerde
--   text terug, en dan valt er niets te kiezen.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

CREATE OR REPLACE FUNCTION public.declaration_compute(
  p_shift_id UUID, p_own_car_km NUMERIC DEFAULT NULL
)
RETURNS TABLE (
  distance_km     NUMERIC,
  reimbursable_km NUMERIC,
  rule            TEXT,
  rate_id         UUID,
  pharmacy_id     TEXT,
  incomplete      BOOLEAN,
  reason          TEXT
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_shift     public.shifts;
  v_home      TEXT;
  v_rate      public.reimbursement_rates;
  -- Waar zodra ÁLLE apotheken van de dienst de standplaats zijn (migratie 020).
  v_home_only BOOLEAN;
  v_count     INT;
  -- Namen van de apotheken in deze dienst waarvoor geen afstand bekend is.
  v_missing   TEXT;
  v_reasons   TEXT[] := ARRAY[]::TEXT[];
  -- Lokale namen, niet de OUT-parameters: pharmacy_id en distance_km heten
  -- precies zoals kolommen in de query's hieronder, en dan weigert plpgsql de
  -- verwijzing als dubbelzinnig.
  v_pharmacy  TEXT;
  v_distance  NUMERIC;
  v_rule      TEXT;
  v_km        NUMERIC;
BEGIN
  SELECT * INTO v_shift FROM public.shifts WHERE id = p_shift_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Dienst % bestaat niet.', p_shift_id;
  END IF;

  SELECT up.home_pharmacy_id INTO v_home
  FROM public.user_profiles up WHERE up.id = v_shift.courier_id;

  v_rate := public.reimbursement_rate_on(v_shift.transport_mode, v_shift.shift_date);
  IF v_rate.id IS NULL THEN
    v_reasons := v_reasons || format('geen tarief voor %s op %s', v_shift.transport_mode, v_shift.shift_date);
  END IF;

  SELECT count(*) INTO v_count
  FROM public.shift_pharmacies sp WHERE sp.shift_id = p_shift_id;

  IF v_count = 0 THEN
    v_reasons := v_reasons || 'de dienst heeft geen apotheek'::TEXT;
  END IF;

  -- Zijn ALLE apotheken van deze dienst de standplaats? Eén andere apotheek is
  -- genoeg om dit onwaar te maken; dan moet de koerier ergens anders heen en
  -- geldt de tak other_pharmacy.
  v_home_only := v_home IS NOT NULL AND v_count > 0 AND NOT EXISTS (
    SELECT 1 FROM public.shift_pharmacies sp
    WHERE sp.shift_id = p_shift_id
      AND sp.pharmacy_id IS DISTINCT FROM v_home
  );

  -- Welke apotheken van deze dienst hebben geen bekende afstand? Bij naam, want
  -- deze tekst komt in het plannerscherm terecht en moet daar bruikbaar zijn.
  SELECT string_agg(COALESCE(p.name, sp.pharmacy_id), ', ' ORDER BY COALESCE(p.name, sp.pharmacy_id))
    INTO v_missing
  FROM public.shift_pharmacies sp
  LEFT JOIN public.pharmacies p ON p.id = sp.pharmacy_id
  WHERE sp.shift_id = p_shift_id
    AND NOT EXISTS (
      SELECT 1 FROM public.courier_distances cd
      WHERE cd.courier_id = v_shift.courier_id AND cd.pharmacy_id = sp.pharmacy_id
    );

  -- Bestemming en afstand.
  IF v_home_only THEN
    v_pharmacy := v_home;
  ELSE
    SELECT sp.pharmacy_id INTO v_pharmacy
    FROM public.shift_pharmacies sp
    JOIN public.courier_distances cd
      ON cd.pharmacy_id = sp.pharmacy_id AND cd.courier_id = v_shift.courier_id
    WHERE sp.shift_id = p_shift_id
    ORDER BY cd.distance_km DESC
    LIMIT 1;
  END IF;

  SELECT cd.distance_km INTO v_distance
  FROM public.courier_distances cd
  WHERE cd.courier_id = v_shift.courier_id AND cd.pharmacy_id = v_pharmacy;

  -- Alleen melden als er überhaupt een apotheek was; anders staat die reden er al.
  IF v_distance IS NULL AND v_count > 0 THEN
    v_reasons := v_reasons || 'geen afstand bekend voor deze koerier en apotheek'::TEXT;
  END IF;

  -- ── De vier takken ────────────────────────────────────────────────────
  IF v_shift.transport_mode = 'car' AND v_shift.car_is_own IS TRUE THEN
    -- Eigen auto: de koerier geeft zelf op en de drempel vervalt volledig.
    -- v_distance blijft staan als referentie, puur om afwijkingen te zien. Een
    -- ontbrekende afstand elders in de dienst doet er hier niet toe: die raakt
    -- de referentie, niet het bedrag.
    v_rule := 'own_car';
    v_km   := p_own_car_km;

  ELSIF v_home IS NULL THEN
    -- Geen standplaats: de hoofdvertakking is niet te bepalen. Terugvallen op de
    -- drempelregel — de zuinigste van de twee — en de rij als onvolledig
    -- markeren, zodat de planner het rechtzet in plaats van het te missen.
    v_reasons := v_reasons || 'koerier heeft geen standplaats'::TEXT;
    v_rule    := 'above_threshold';

    IF v_missing IS NOT NULL THEN
      -- Ook hier leunt de uitkomst op "de verste bekende", en die is geen
      -- maximum zolang er een afstand ontbreekt.
      v_reasons := v_reasons || format('geen afstand bekend voor: %s', v_missing);
      v_km := NULL;
    ELSIF v_distance IS NULL OR v_rate.id IS NULL THEN
      v_km := NULL;
    ELSIF v_distance > v_rate.threshold_km THEN
      v_km := v_distance - v_rate.threshold_km;
    ELSE
      v_rule := 'none'; v_km := 0;
    END IF;

  ELSIF NOT v_home_only THEN
    -- Er zit ten minste één andere apotheek dan de standplaats in de dienst:
    -- volledige afstand naar de verste, drempel vervalt.
    v_rule := 'other_pharmacy';

    IF v_missing IS NOT NULL THEN
      -- "De verste" is niet vast te stellen zolang er een afstand ontbreekt. Het
      -- getal dat de join oplevert is dan een ondergrens, en dat mag niet
      -- stilzwijgend als vergoeding doorgaan.
      v_reasons := v_reasons || format('geen afstand bekend voor: %s', v_missing);
      v_km := NULL;
    ELSE
      v_km := v_distance;
    END IF;

  ELSE
    -- Alle apotheken van de dienst zijn de standplaats: afstand boven de
    -- drempel, minimaal 0.
    IF v_distance IS NULL OR v_rate.id IS NULL THEN
      v_rule := 'above_threshold'; v_km := NULL;
    ELSIF v_distance > v_rate.threshold_km THEN
      v_rule := 'above_threshold'; v_km := v_distance - v_rate.threshold_km;
    ELSE
      v_rule := 'none'; v_km := 0;
    END IF;
  END IF;

  distance_km     := v_distance;
  reimbursable_km := v_km;
  rule            := v_rule;
  rate_id         := v_rate.id;
  pharmacy_id     := v_pharmacy;
  incomplete      := array_length(v_reasons, 1) IS NOT NULL;
  reason          := CASE WHEN incomplete THEN array_to_string(v_reasons, '; ') END;
  RETURN NEXT;
END;
$$;

-- ────────────────────────────────────────────────────────────────────────
-- Rechten. CREATE OR REPLACE laat de bestaande ACL staan; dit is een herhaling
-- van migratie 018, zodat dit bestand op zichzelf klopt.
-- ────────────────────────────────────────────────────────────────────────
REVOKE ALL     ON FUNCTION public.declaration_compute(UUID, NUMERIC) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.declaration_compute(UUID, NUMERIC) TO service_role;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie — de drie zinnen staan nu met een cast in de functie.
-- ────────────────────────────────────────────────────────────────────────
SELECT
  pg_get_functiondef(p.oid) LIKE '%geen apotheek''::TEXT%'          AS cast_geen_apotheek,
  pg_get_functiondef(p.oid) LIKE '%koerier en apotheek''::TEXT%'    AS cast_geen_afstand,
  pg_get_functiondef(p.oid) LIKE '%geen standplaats''::TEXT%'       AS cast_geen_standplaats
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'declaration_compute';

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
