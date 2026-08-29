-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — nadeclaratie: scherpere tak-keuze — migratie 020
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 018 en 019 eerst. Deze migratie vervangt uitsluitend de body
-- van declaration_compute(); 018 blijft staan zoals hij gedraaid is.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien, en draai daarna       │
-- │ supabase/tests/020_declaration_branch_test.sql.                        │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAT ER VERANDERT
--
-- 1. WANNEER GELDT DE STANDPLAATSTAK.
--    Tot nu toe was dat zodra de standplaats érgens tussen de apotheken van de
--    dienst zat. Een dienst bij de eigen standplaats én een apotheek verderop
--    viel daarmee onder de drempelregel, terwijl de koerier wel degelijk naar
--    die andere apotheek moest.
--
--    Voortaan geldt de standplaatstak alleen als ÁLLE apotheken van de dienst de
--    standplaats zijn. Zit er één andere bij, dan is het other_pharmacy en wordt
--    de verste bekende afstand volledig vergoed.
--
--    De variabele heet daarom niet langer v_home_here maar v_home_only: de
--    betekenis is veranderd, en dan hoort de naam mee te veranderen.
--
-- 2. EEN ONTBREKENDE AFSTAND MAG NIET STIL TOT EEN LAGER BEDRAG LEIDEN.
--    De bestemming wordt in die tak gekozen met een JOIN op courier_distances.
--    Een apotheek zonder bekende afstand valt uit die join weg, en dan wint een
--    apotheek die dichterbij ligt — de uitkomst is dan geen maximum maar een
--    ondergrens, en niets liet dat zien.
--
--    Voortaan: zodra er in de dienst een apotheek zit waarvoor geen afstand
--    bekend is, is "de verste" niet vast te stellen. Het bedrag wordt dan NULL
--    (onbekend, niet te laag) en de reden noemt de apotheken bij naam.
--
--    Dit volgt dezelfde regel als de rest van de keten: nul, onbekend en te laag
--    moeten uit elkaar te houden zijn, en de planner moet het verschil zien.
--    Bij eigen auto verandert er niets — daar komt het bedrag van de koerier en
--    is de afstand alleen referentie.
--
-- 3. Een dienst zónder apotheken krijgt een eigen, leesbare reden in plaats van
--    "geen afstand bekend voor deze koerier en apotheek".
--
-- Signatuur, returntype en kolomnamen blijven gelijk; alleen de body wijzigt.
-- De rechten van 018 blijven bij CREATE OR REPLACE staan, maar worden onderaan
-- voor de zekerheid opnieuw gezet, zodat dit bestand op zichzelf klopt.
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
    v_reasons := v_reasons || 'de dienst heeft geen apotheek';
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
    v_reasons := v_reasons || 'geen afstand bekend voor deze koerier en apotheek';
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
    v_reasons := v_reasons || 'koerier heeft geen standplaats';
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
-- Rechten. CREATE OR REPLACE laat de bestaande ACL staan, dus dit is een
-- herhaling van migratie 018 — hier zodat dit bestand op zichzelf klopt en een
-- functie die ooit met andere rechten is neergezet toch goed eindigt.
-- ────────────────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.declaration_compute(UUID, NUMERIC) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.declaration_compute(UUID, NUMERIC) TO service_role;


-- ────────────────────────────────────────────────────────────────────────
-- Hertellen. De regel is veranderd, dus de computed_*-kolommen van bestaande
-- declaraties zijn onder de oude regel berekend. Goedgekeurde declaraties
-- blijven ongemoeid: die zijn uitbetaald, en hun rate_id legt vast waarop.
-- De invoer van de koerier wordt niet aangeraakt.
-- ────────────────────────────────────────────────────────────────────────
DO $$
DECLARE v_id UUID; v_n INT := 0;
BEGIN
  FOR v_id IN SELECT id FROM public.shift_declarations WHERE status <> 'approved' LOOP
    PERFORM public.declaration_recompute(v_id);
    v_n := v_n + 1;
  END LOOP;
  RAISE NOTICE '% declaratie(s) opnieuw doorgerekend onder de regel van migratie 020.', v_n;
END $$;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie — verwacht: geen enkele declaratie waarin other_pharmacy geldt
-- terwijl er een bedrag staat én een apotheek zonder bekende afstand in de
-- dienst zit. Dat was precies het stille geval dat deze migratie afsluit.
-- ────────────────────────────────────────────────────────────────────────
SELECT d.id, d.computed_rule, d.computed_reimbursable_km, d.computed_reason
FROM public.shift_declarations d
WHERE d.computed_rule = 'other_pharmacy'
  AND d.computed_reimbursable_km IS NOT NULL
  AND EXISTS (
    SELECT 1 FROM public.shift_pharmacies sp
    WHERE sp.shift_id = d.shift_id
      AND NOT EXISTS (
        SELECT 1 FROM public.courier_distances cd
        WHERE cd.courier_id = d.courier_id AND cd.pharmacy_id = sp.pharmacy_id
      )
  );   -- verwacht: geen rijen

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
