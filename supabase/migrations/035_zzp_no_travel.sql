-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — zzp'ers krijgen geen kilometervergoeding — 035
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Deze migratie staat op zichzelf: migratie 029 (employees) is NIET nodig.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien, en draai daarna       │
-- │ supabase/tests/035_zzp_no_travel_test.sql.                             │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- HET PROBLEEM
--   declaration_compute() rekende voor iedereen een kilometervergoeding uit
--   volgens de vierdelige regel. Dat klopt alleen voor loondienst. Een zzp'er
--   heeft geen recht op reiskostenvergoeding; die factureert zijn werkelijke
--   kosten, net als parkeren of een veerpont.
--
--   Vulde een zzp'er zijn kilometers in als onkostenpost, dan kwam daar de
--   berekende vergoeding nog eens bovenop en werd dezelfde rit twee keer aan de
--   apotheek doorbelast.
--
-- DE NIEUWE TAK
--   Vóór de vier bestaande takken: is de koerier zzp, dan rule = 'zzp',
--   reimbursable_km = NULL en geen tarief, dus geen bedrag. De referentie-
--   afstand blijft staan als informatie.
--
--   Dit is nadrukkelijk GEEN incomplete-geval. Bij een zzp'er hoort er niets te
--   staan; dat is de bedoeling en niet iets wat de planner moet rechtzetten. De
--   redenen die tot dat punt verzameld zijn ("geen tarief", "geen afstand
--   bekend") gaan over een berekening die hier niet plaatsvindt, en worden dus
--   gewist. Een markering op een regel die klopt leert de planner om
--   markeringen te negeren.
--
-- WAAR 'ZZP' VANDAAN KOMT
--   Vandaag: user_profiles.employmentType, gelezen via to_jsonb() — zie het
--   kader in migratie 028. Die kolom is in deze repo niet te verifiëren, en een
--   rechtstreekse verwijzing zou de functie onaanmaakbaar maken als hij
--   ontbreekt.
--
--   Straks: employees.employment_type (migratie 029), te onderhouden in het
--   scherm Medewerkers. Die tabel bestaat nog niet — 029 is nooit gedraaid en
--   er hangt nog een ontwerpvraag aan. Daarom staat die tak achter een
--   to_regclass()-controle: hij doet niets zolang de tabel er niet is, en gaat
--   vanzelf gelden zodra 029 gedraaid is. Zonder die constructie zou er ná 029
--   nóg een migratie nodig zijn die niemand zich dan nog herinnert.
--
--   Een LANGUAGE sql-functie wordt bij het aanmaken al gecontroleerd op
--   bestaande tabellen; die kan dus niet naar employees verwijzen. Vandaar
--   plpgsql met EXECUTE.
--
-- ┌─ LET OP — MOGELIJK DOET DEZE MIGRATIE VOORLOPIG NIETS ─────────────────┐
-- │ Bestaat user_profiles.employmentType niet (of staat hij overal leeg),   │
-- │ dan geldt niemand als zzp'er en verandert er geen enkele berekening.    │
-- │ Dat is geen fout maar de veilige kant: onbekend is GEEN zzp, want een   │
-- │ vergoeding stilzwijgend laten vervallen kost een koerier geld zonder    │
-- │ dat iemand het ziet. De eerste verificatiequery onderaan laat zien wie  │
-- │ er nu als zzp'er geldt — staat daar niemand, dan wacht dit op 029 of op │
-- │ het vullen van dat veld.                                               │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAT ER NIET VERANDERT
--   De vier bestaande takken zijn letterlijk overgenomen uit migratie 027,
--   inclusief de ::TEXT-casts op de vaste zinnen. declaration_submit(),
--   declaration_review() en invoice_lines() blijven ongemoeid: met
--   reimbursable_km = NULL levert de bestaande berekening in invoice_lines()
--   vanzelf geen reiskostenbedrag op.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────
-- 1. 'zzp' toelaten als uitkomst.
--    De CHECK stond inline in migratie 018 en heet daarom zoals hieronder.
--    Zonder deze stap weigert elke herberekening van een zzp-declaratie.
-- ────────────────────────────────────────────────────────────────────────
ALTER TABLE public.shift_declarations
  DROP CONSTRAINT IF EXISTS shift_declarations_computed_rule_check;

ALTER TABLE public.shift_declarations
  ADD CONSTRAINT shift_declarations_computed_rule_check
  CHECK (computed_rule IN ('own_car', 'other_pharmacy', 'above_threshold', 'none', 'zzp'));


-- ────────────────────────────────────────────────────────────────────────
-- 2. De contractvorm — één plek waar die vraag beantwoord wordt, want hij
--    wordt op drie plekken gesteld: bij het rekenen, op de invulpagina en bij
--    de bonverwachting.
--
--    declaration_employment_type() levert de ruwe waarde: kleine letters,
--    zonder spaties, en NULL als er niets bekend is. Leeg en onbekend zijn
--    hier hetzelfde; dat scheelt overal een tweede vergelijking.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.declaration_employment_type(p_courier_id UUID)
RETURNS TEXT
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_type TEXT;
  v_emp  TEXT;
BEGIN
  -- De bron die er vandaag is. to_jsonb() omdat de kolom niet te verifiëren is:
  -- bestaat hij niet, dan levert dit NULL in plaats van een functie die niet
  -- aangemaakt kan worden. Zie het kader in migratie 028.
  SELECT NULLIF(lower(btrim(to_jsonb(up) ->> 'employmentType')), '')
    INTO v_type
  FROM public.user_profiles up
  WHERE up.id = p_courier_id;

  -- Bestaat employees (migratie 029) al, dan wint wat daar staat: dat is de
  -- lijst die in het scherm Medewerkers onderhouden wordt. to_regclass geeft
  -- NULL zolang de tabel er niet is, en dan blijft dit blok ongebruikt.
  -- Dynamisch, want een verwijzing naar een niet-bestaande tabel maakt zelfs
  -- een plpgsql-functie onbruikbaar zodra hij hier langskomt.
  IF to_regclass('public.employees') IS NOT NULL THEN
    EXECUTE $q$
      SELECT NULLIF(lower(btrim(e.employment_type)), '')
      FROM public.employees e
      WHERE e.user_profile_id = $1
      LIMIT 1
    $q$ INTO v_emp USING p_courier_id;

    -- Alleen overschrijven als er werkelijk iets staat: een medewerker zonder
    -- ingevulde contractvorm hoort het profielveld niet te wissen.
    IF v_emp IS NOT NULL THEN
      v_type := v_emp;
    END IF;
  END IF;

  RETURN v_type;
END;
$fn$;

COMMENT ON FUNCTION public.declaration_employment_type(UUID) IS
  'Contractvorm van een koerier (migratie 035). Bron: '
  'user_profiles.employmentType, overschreven door employees.employment_type '
  'zodra migratie 029 gedraaid is. NULL = onbekend.';

-- Zzp of niet. Onbekend telt als niet-zzp: dan blijft de vierdelige regel
-- gelden, want een vergoeding stilzwijgend laten vervallen kost een koerier
-- geld zonder dat iemand het ziet.
CREATE OR REPLACE FUNCTION public.declaration_is_contractor(p_courier_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT COALESCE(public.declaration_employment_type(p_courier_id) = 'zzp', false);
$fn$;

-- Dezelfde bron voor de bonverwachting, zodat er maar één plek is waar de
-- contractvorm vandaan komt. De regel zelf blijft gelijk aan migratie 028,
-- inclusief "onbekend → geen markering": liever geen markering dan bij
-- iedereen één. Let op het verschil met de functie hierboven — daar is
-- onbekend hetzelfde als loondienst, hier juist niet.
CREATE OR REPLACE FUNCTION public.declaration_expects_receipt(p_courier_id UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT COALESCE(public.declaration_employment_type(p_courier_id) <> 'zzp', false);
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 3. declaration_compute — de vijfde tak, vóór de andere vier.
--    Body letterlijk uit migratie 027 (die 020 met casts overnam), met alleen
--    de zzp-tak erbij.
-- ────────────────────────────────────────────────────────────────────────
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
  -- Migratie 035: geen kilometervergoeding voor zzp'ers.
  v_zzp       BOOLEAN;
BEGIN
  SELECT * INTO v_shift FROM public.shifts WHERE id = p_shift_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Dienst % bestaat niet.', p_shift_id;
  END IF;

  SELECT up.home_pharmacy_id INTO v_home
  FROM public.user_profiles up WHERE up.id = v_shift.courier_id;

  v_zzp := public.declaration_is_contractor(v_shift.courier_id);

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

  -- ── De vijf takken ────────────────────────────────────────────────────
  IF v_zzp THEN
    -- Zzp: geen reiskostenvergoeding. Kilometers gaan als onkostenpost mee,
    -- net als parkeren of een veerpont, en worden daar doorbelast.
    --
    -- v_distance blijft staan als referentie. De verzamelde redenen gaan wél
    -- weg: die gaan over een tarief en een afstand die hier niets uitrekenen.
    -- Er hoort niets te staan, dus is er ook niets onvolledig.
    v_rule    := 'zzp';
    v_km      := NULL;
    v_reasons := ARRAY[]::TEXT[];

  ELSIF v_shift.transport_mode = 'car' AND v_shift.car_is_own IS TRUE THEN
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
  -- Geen tarief bij zzp: een tarief in de rij suggereert een recht op
  -- vergoeding dat er niet is, en declaration_overview() zou er een bedrag
  -- mee uitrekenen zodra er ooit kilometers naast komen te staan.
  rate_id         := CASE WHEN v_rule = 'zzp' THEN NULL ELSE v_rate.id END;
  pharmacy_id     := v_pharmacy;
  incomplete      := array_length(v_reasons, 1) IS NOT NULL;
  reason          := CASE WHEN incomplete THEN array_to_string(v_reasons, '; ') END;
  RETURN NEXT;
END;
$$;

-- CREATE OR REPLACE laat de bestaande ACL staan; herhaald zodat dit bestand op
-- zichzelf klopt.
REVOKE ALL     ON FUNCTION public.declaration_compute(UUID, NUMERIC) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.declaration_compute(UUID, NUMERIC) TO service_role;


-- ────────────────────────────────────────────────────────────────────────
-- 4. declaration_by_token — de invulpagina moet weten of ze de reiskostenvraag
--    moet tonen. Body letterlijk uit migratie 028, met één kolom erbij; een
--    returntype wijzigen kan niet met CREATE OR REPLACE, dus DROP + CREATE +
--    opnieuw GRANT.
--
--    De pagina krijgt een boolean en geen contractvorm: wat er op het scherm
--    hoort te staan is hier een afgeleide, en de pagina hoeft niets te weten
--    over arbeidsverhoudingen.
-- ────────────────────────────────────────────────────────────────────────
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
  review_note       TEXT,
  expenses          JSONB,
  expects_receipt   BOOLEAN,
  -- Migratie 035: bij true toont de pagina de reiskostenvraag niet, en zegt ze
  -- bij de onkosten dat kilometers daar thuishoren.
  is_contractor     BOOLEAN
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
         d.review_note,
         (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                     'description', e.description, 'amount_eur', e.amount_eur)
                     ORDER BY e.created_at), '[]'::jsonb)
            FROM public.declaration_expenses e WHERE e.declaration_id = d.id),
         public.declaration_expects_receipt(d.courier_id),
         public.declaration_is_contractor(d.courier_id)
  FROM public.shift_declarations d
  JOIN public.shifts s         ON s.id  = d.shift_id
  JOIN public.user_profiles up ON up.id = d.courier_id
  WHERE d.token_hash = public.declaration_hash_token(p_token)
    AND d.token_expires_at > now();
$$;

REVOKE ALL     ON FUNCTION public.declaration_by_token(TEXT) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.declaration_by_token(TEXT) TO service_role;


-- ────────────────────────────────────────────────────────────────────────
-- 5. Alles wat nog niet is goedgekeurd opnieuw doorrekenen, zoals in migratie
--    020. Goedgekeurde declaraties blijven staan: die zijn beoordeeld en
--    mogelijk al uitbetaald, en met terugwerkende kracht een vergoeding
--    intrekken is een besluit, geen migratie.
-- ────────────────────────────────────────────────────────────────────────
DO $$
DECLARE v_id UUID; v_n INT := 0; v_zzp INT := 0;
BEGIN
  FOR v_id IN SELECT id FROM public.shift_declarations WHERE status <> 'approved' LOOP
    PERFORM public.declaration_recompute(v_id);
    v_n := v_n + 1;
  END LOOP;

  SELECT count(*) INTO v_zzp
  FROM public.shift_declarations WHERE computed_rule = 'zzp';

  RAISE NOTICE '% declaratie(s) opnieuw doorgerekend; % daarvan vallen onder de zzp-tak.', v_n, v_zzp;
END $$;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie
--   1. Wie er als zzp'er geldt. Klopt dit rijtje niet, dan staat het antwoord
--      in Medewerkers en niet in deze migratie.
--   2. Geen enkele zzp-declaratie mag een vergoeding of een markering hebben.
--   3. Het geval waar het om begon: kilometers als onkostenpost naast een
--      berekende vergoeding. Verwacht: geen rijen meer bij zzp'ers.
-- ────────────────────────────────────────────────────────────────────────
SELECT up.name,
       public.declaration_employment_type(up.id) AS contractvorm,
       public.declaration_is_contractor(up.id)   AS zzp
FROM public.user_profiles up
WHERE up.role = 'courier'
ORDER BY 3 DESC, 1;
-- Staat contractvorm overal op NULL, dan is er nog niets te herkennen: de
-- kolom employmentType ontbreekt of is leeg, en employees bestaat nog niet.

SELECT count(*) AS zzp_met_bedrag_of_markering
FROM public.shift_declarations
WHERE computed_rule = 'zzp'
  AND (computed_reimbursable_km IS NOT NULL OR rate_id IS NOT NULL OR computed_incomplete);
  -- verwacht: 0

SELECT d.id, up.name, d.computed_rule, d.computed_reimbursable_km, e.description
FROM public.shift_declarations d
JOIN public.user_profiles up          ON up.id = d.courier_id
JOIN public.declaration_expenses e    ON e.declaration_id = d.id
WHERE (e.description ILIKE '%km%' OR e.description ILIKE '%kilometer%')
  AND d.computed_reimbursable_km IS NOT NULL
ORDER BY d.id;   -- verwacht: alleen nog loondienst, en die hoort de planner te zien

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
