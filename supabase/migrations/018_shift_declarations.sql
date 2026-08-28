-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — nadeclaratie: datamodel en de rekenregel — 018
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai 001 t/m 017 eerst. Deze migratie raakt de mailketen van 016/017 NIET;
-- die komt in 019 aan de beurt en dan alleen additief.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien, en draai daarna       │
-- │ supabase/tests/018_shift_declarations_test.sql.                        │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- Het volledige ontwerp staat in docs/FASE6_NADECLARATIE_ONTWERP.md.
--
-- DE REKENREGEL (vier takken, en twee ervan zijn tegenintuïtief)
--   eigen auto?
--   ├─ ja  → opgegeven km's × autotarief                       → own_car
--   └─ nee → andere apotheek dan de standplaats?
--            ├─ ja  → volledige afstand vergoed                → other_pharmacy
--            └─ nee → afstand − drempel, minimaal 0            → above_threshold / none
--
--   Bij eigen auto vervalt de drempel volledig: ook wie op 2 km woont krijgt
--   alle opgegeven kilometers. Bij een andere apotheek dan de standplaats
--   vervalt de drempel ook: wie op 3 km van zijn standplaats woont en naar een
--   apotheek op 4 km gaat krijgt die 4 km — ook al rijdt hij nauwelijks verder.
--   Beide zijn bewust zo bevestigd en volgen uit de regel.
--
--   Afstand is de ENKELE REIS van het woonadres naar de apotheek van díe dienst,
--   over de werkelijke route (niet hemelsbreed).
--
-- TWEE AFWIJKINGEN VAN HET ONTWERPDOCUMENT, en waarom
--   1. Het ontwerp schrijft `public.profiles`. Die tabel bestaat hier niet: de
--      gedeelde database heeft `public.user_profiles` (zie migratie 001).
--   2. Het ontwerp typeert apotheekverwijzingen als UUID. `pharmacies.id` is in
--      dit schema TEXT (bv. 'ph-1779784742417'), zoals migratie 001 al vastlegt.
--      Alle apotheekverwijzingen hieronder zijn dus TEXT.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────
-- 1. Standplaats per koerier.
--    courier_pharmacy_access regelt TOEGANG, niet thuisbasis: een koerier is aan
--    meerdere apotheken gekoppeld en daar is geen "de zijne" uit af te leiden.
--    Zonder dit veld is de hoofdvertakking van de rekenregel niet te bepalen.
--
--    Additief en nullable op een gedeelde productietabel — zelfde omgang als
--    migratie 004 met pharmacies. Er worden bewust GEEN kolomrechten uitgedeeld:
--    lezen en schrijven van dit veld loopt via de SECURITY DEFINER-functies in
--    punt 11, die zelf op is_privileged() controleren. Een koerier mag zijn eigen
--    standplaats niet zetten — dat bepaalt zijn vergoeding.
-- ────────────────────────────────────────────────────────────────────────
ALTER TABLE public.user_profiles
  ADD COLUMN IF NOT EXISTS home_pharmacy_id TEXT REFERENCES public.pharmacies(id);

COMMENT ON COLUMN public.user_profiles.home_pharmacy_id IS
  'Standplaats van een koerier: de apotheek waar hij normaal begint. Bepaalt de '
  'hoofdvertakking van de reiskostenregel (migratie 018). NULL = onbekend; de '
  'declaratie valt dan terug op de drempelregel en wordt als onvolledig gemarkeerd.';


-- ────────────────────────────────────────────────────────────────────────
-- 2. courier_distances — afstand koerier ↔ apotheek.
--
--    HET WOONADRES WORDT NIET OPGESLAGEN. Het adres wordt eenmalig in een
--    formulier ingevoerd, gaat naar de geocoder, en alleen de AFSTANDEN komen
--    terug. Geen bewaartermijn op adresgegevens nodig, en een lek levert
--    niemands woonplaats op.
--
--    Bij het invoeren van een adres worden meteen de afstanden naar álle
--    apotheken berekend waar de koerier toegang toe heeft, zodat de tak
--    "andere apotheek" ook werkt.
--
--    source legt vast hoe betrouwbaar het getal is:
--      route    — geslaagde routeberekening
--      fallback — teruggevallen op hemelsbreed × omrijfactor
--      manual   — met de hand ingevoerd door de planner
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.courier_distances (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  courier_id   UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  pharmacy_id  TEXT NOT NULL REFERENCES public.pharmacies(id)    ON DELETE CASCADE,
  distance_km  NUMERIC(6,2) NOT NULL CHECK (distance_km >= 0),
  source       TEXT NOT NULL CHECK (source IN ('route', 'fallback', 'manual')),
  computed_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (courier_id, pharmacy_id)
);

COMMENT ON TABLE public.courier_distances IS
  'Enkele-reisafstand woonadres → apotheek per koerier, over de werkelijke route. '
  'Het adres zelf staat hier bewust NIET: alleen de uitkomst wordt bewaard.';


-- ────────────────────────────────────────────────────────────────────────
-- 3. reimbursement_rates — tarieven met ingangsdatum.
--    Tarieven wijzigen per jaar. Zonder ingangsdatum moet je bij elke wijziging
--    je hele historie hertellen. Een declaratie legt vast wélk tarief gold op de
--    dienstdatum (rate_id), zodat een oude uitbetaling herleidbaar blijft.
--
--    De drempel hoort bij het tarief en niet in de code: hij is instelbaar en
--    kan met een tariefwijziging meebewegen.
--    transport_mode spiegelt shifts.transport_mode (migratie 003).
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.reimbursement_rates (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  transport_mode TEXT NOT NULL CHECK (transport_mode IN ('bike', 'car')),
  rate_per_km    NUMERIC(6,4) NOT NULL CHECK (rate_per_km >= 0),
  threshold_km   NUMERIC(6,2) NOT NULL DEFAULT 10 CHECK (threshold_km >= 0),
  effective_from DATE NOT NULL,
  note           TEXT,
  UNIQUE (transport_mode, effective_from)
);

-- Startwaarden, zodat er iets te rekenen valt. €0,23/km is de onbelaste
-- kilometervergoeding, de drempel van 10 km komt uit het ontwerp.
-- ⚠ CONTROLEER DEZE TWEE RIJEN voordat er declaraties uitgaan: zonder rij rekent
-- er niets, met een verkeerde rij rekent alles verkeerd.
-- Een tariefwijziging is voortaan een INSERT met een nieuwe effective_from, nooit
-- een UPDATE van een bestaande rij — die rij zit vast in uitbetaalde declaraties.
INSERT INTO public.reimbursement_rates (transport_mode, rate_per_km, threshold_km, effective_from, note)
VALUES
  ('car',  0.2300, 10, DATE '2025-01-01', 'startwaarde bij migratie 018 — controleer voor gebruik'),
  ('bike', 0.2300, 10, DATE '2025-01-01', 'startwaarde bij migratie 018 — controleer voor gebruik')
ON CONFLICT (transport_mode, effective_from) DO NOTHING;


-- ────────────────────────────────────────────────────────────────────────
-- 4. shift_declarations — één rij per dienst.
--    Bewust een eigen tabel en geen kolommen op shifts: dat zou planning en
--    verantwoording door elkaar mengen, en shifts is de tabel waar de triggers
--    van 016 aan hangen.
--
--    De rij bevat naast elkaar wat de KOERIER opgaf en wat het SYSTEEM berekende.
--    Het berekende getal is een referentie om afwijkingen zichtbaar te maken,
--    geen afkeuringsgrond: bij eigen auto is het opgegeven aantal niet
--    controleerbaar en dat is geaccepteerd.
--
--    NIET TE VERWARREN MET shift_time_reports (migratie 006). Die tabel bevat de
--    uit scandata berekende tijd van de bezorg-app; deze bevat wat de koerier ná
--    afloop zelf opgeeft, langs een link in de mail en zonder in te loggen. Twee
--    bronnen die elkaar controleren, dus geen samenvoeging.
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.shift_declarations (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shift_id    UUID NOT NULL UNIQUE REFERENCES public.shifts(id) ON DELETE CASCADE,
  courier_id  UUID NOT NULL REFERENCES public.user_profiles(id),
  status      TEXT NOT NULL DEFAULT 'open'
              CHECK (status IN ('open', 'submitted', 'approved', 'disputed')),

  -- ── wat de koerier invult ──────────────────────────────────────────────
  actual_start   TIME,
  actual_end     TIME,
  claims_travel  BOOLEAN,
  own_car_km     NUMERIC(6,1) CHECK (own_car_km >= 0),
  courier_note   TEXT,

  -- ── wat het systeem berekende, als referentie ──────────────────────────
  computed_distance_km     NUMERIC(6,2),
  computed_reimbursable_km NUMERIC(6,2),
  computed_rule            TEXT CHECK (computed_rule IN
                             ('own_car', 'other_pharmacy', 'above_threshold', 'none')),
  rate_id                  UUID REFERENCES public.reimbursement_rates(id),

  -- Welke apotheek de berekening als bestemming nam. Een dienst kan meerdere
  -- apotheken hebben (shift_pharmacies is m:n); zonder deze kolom is achteraf
  -- niet na te gaan welke afstand gebruikt is.
  computed_pharmacy_id     TEXT REFERENCES public.pharmacies(id),

  -- Onvolledig = er ontbrak iets om de regel volledig toe te passen (geen
  -- standplaats, geen afstand, geen tarief). NOOIT stilzwijgend 0 vergoeden: de
  -- planner moet het verschil zien tussen "nul" en "onbekend".
  computed_incomplete      BOOLEAN NOT NULL DEFAULT false,
  computed_reason          TEXT,

  -- ── toegang zonder inloggen ────────────────────────────────────────────
  -- Alleen de hash staat hier; het token zelf bestaat uitsluitend in de mail.
  -- Zie declaration_issue_token() in migratie 019.
  token_hash       TEXT NOT NULL UNIQUE,
  token_expires_at TIMESTAMPTZ NOT NULL,

  submitted_at TIMESTAMPTZ,
  reviewed_at  TIMESTAMPTZ,
  reviewed_by  UUID REFERENCES public.user_profiles(id),
  -- Waarom de planner betwist heeft. Los van courier_note: dat is wat de koerier
  -- zei. Een betwisting zonder reden is voor de volgende lezer waardeloos.
  review_note  TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS shift_declarations_status_idx
  ON public.shift_declarations (status);
CREATE INDEX IF NOT EXISTS shift_declarations_courier_idx
  ON public.shift_declarations (courier_id);


-- ────────────────────────────────────────────────────────────────────────
-- 5. own_car_km hoort alleen bij een dienst met een EIGEN auto.
--    Dit kan geen CHECK zijn: de voorwaarde staat op shifts, en een CHECK mag
--    geen andere tabel raadplegen. Vandaar een trigger. Zonder deze bewaking
--    sluipen er kilometers binnen bij fietsdiensten.
--
--    car_is_own IS NULL bij een autodienst betekent sinds migratie 013 "nog niet
--    bekend". Dat is géén eigen auto, dus kilometers zijn dan ook niet toegestaan
--    — de planner moet de keuze eerst vastleggen.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.declaration_check_own_car()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_ok BOOLEAN;
BEGIN
  IF NEW.own_car_km IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT s.transport_mode = 'car' AND s.car_is_own IS TRUE
    INTO v_ok
  FROM public.shifts s WHERE s.id = NEW.shift_id;

  IF v_ok IS NOT TRUE THEN
    RAISE EXCEPTION 'own_car_km mag alleen gevuld zijn bij een dienst met transport_mode = car en car_is_own = true (dienst %).', NEW.shift_id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS declaration_own_car_chk ON public.shift_declarations;
CREATE TRIGGER declaration_own_car_chk
  BEFORE INSERT OR UPDATE OF own_car_km, shift_id ON public.shift_declarations
  FOR EACH ROW EXECUTE FUNCTION public.declaration_check_own_car();


-- ────────────────────────────────────────────────────────────────────────
-- 6. Tokens — genereren en hashen.
--    Minimaal 32 bytes, cryptografisch random. gen_random_bytes komt uit
--    pgcrypto; staat die extensie er niet, dan vallen we terug op twee UUID's
--    (Postgres 13+ vult die uit dezelfde CSPRNG) — samen 64 hextekens.
--    De hash is SHA-256; sha256() zit sinds Postgres 11 in de kern, dus dat pad
--    heeft geen extensie nodig en kan niet wegvallen.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.declaration_hash_token(p_token TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
  SELECT encode(sha256(convert_to(p_token, 'utf8')), 'hex');
$$;

CREATE OR REPLACE FUNCTION public.declaration_new_token()
RETURNS TEXT
LANGUAGE plpgsql VOLATILE SET search_path = public, extensions AS $$
DECLARE v_token TEXT;
BEGIN
  BEGIN
    v_token := encode(gen_random_bytes(32), 'hex');
  EXCEPTION WHEN undefined_function THEN
    v_token := replace(gen_random_uuid()::TEXT, '-', '')
            || replace(gen_random_uuid()::TEXT, '-', '');
  END;
  RETURN v_token;
END;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 7. Het tarief dat gold op een datum.
--    De jongste ingangsdatum die niet ná de dienstdatum ligt. Een tarief dat
--    later ingaat telt niet mee, ook niet als het al ingevoerd is.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.reimbursement_rate_on(p_mode TEXT, p_date DATE)
RETURNS public.reimbursement_rates
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT r.* FROM public.reimbursement_rates r
  WHERE r.transport_mode = p_mode
    AND r.effective_from <= p_date
  ORDER BY r.effective_from DESC
  LIMIT 1;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 8. declaration_compute — de rekenregel, op één plek.
--
--    Wordt twee keer aangeroepen: bij het aanmaken van de declaratie (dan is
--    p_own_car_km nog NULL) en bij het indienen (dan staat het opgegeven aantal
--    erin). De uitkomst overschrijft de computed_*-kolommen; de invoer van de
--    koerier blijft ongemoeid.
--
--    WELKE APOTHEEK. Een dienst kan meerdere apotheken hebben. Staat de
--    standplaats ertussen, dan is dát de bestemming — daar begint de koerier.
--    Anders de apotheek met de GROOTSTE bekende afstand: bij een dienst over
--    meerdere apotheken is niet vast te stellen waar hij begonnen is, en dan is
--    de keuze die de koerier niet benadeelt de enige verdedigbare. Welke het werd
--    staat in computed_pharmacy_id, zodat de planner het na kan lopen.
--
--    ONVOLLEDIG. Ontbreekt de standplaats, de afstand of het tarief, dan valt de
--    berekening terug op wat wél kan en zet incomplete + reden. Er wordt nooit
--    stilzwijgend 0 vergoed: nul en onbekend moeten uit elkaar te houden zijn.
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
  v_home_here BOOLEAN;
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

  -- Staat de standplaats tussen de apotheken van deze dienst?
  v_home_here := v_home IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.shift_pharmacies sp
    WHERE sp.shift_id = p_shift_id AND sp.pharmacy_id = v_home
  );

  -- Bestemming en afstand.
  IF v_home_here THEN
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

  IF v_distance IS NULL THEN
    v_reasons := v_reasons || 'geen afstand bekend voor deze koerier en apotheek';
  END IF;

  -- ── De vier takken ────────────────────────────────────────────────────
  IF v_shift.transport_mode = 'car' AND v_shift.car_is_own IS TRUE THEN
    -- Eigen auto: de koerier geeft zelf op en de drempel vervalt volledig.
    -- v_distance blijft staan als referentie, puur om afwijkingen te zien.
    v_rule := 'own_car';
    v_km   := p_own_car_km;

  ELSIF v_home IS NULL THEN
    -- Geen standplaats: de hoofdvertakking is niet te bepalen. Terugvallen op de
    -- drempelregel — de zuinigste van de twee — en de rij als onvolledig
    -- markeren, zodat de planner het rechtzet in plaats van het te missen.
    v_reasons := v_reasons || 'koerier heeft geen standplaats';
    IF v_distance IS NULL OR v_rate.id IS NULL THEN
      v_rule := 'above_threshold'; v_km := NULL;
    ELSIF v_distance > v_rate.threshold_km THEN
      v_rule := 'above_threshold'; v_km := v_distance - v_rate.threshold_km;
    ELSE
      v_rule := 'none'; v_km := 0;
    END IF;

  ELSIF NOT v_home_here THEN
    -- Andere apotheek dan de standplaats: volledige afstand, drempel vervalt.
    v_rule := 'other_pharmacy';
    v_km   := v_distance;

  ELSE
    -- Standplaats: afstand boven de drempel, minimaal 0.
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
-- 9. declaration_recompute — de uitkomst op de rij zetten.
--    Aparte functie, zodat de sweep (019), het indienen (019) en een handmatige
--    hertelling na een gecorrigeerde afstand of een nieuw tarief exact dezelfde
--    weg lopen.
--
--    De opgegeven kilometers tellen alleen mee als de koerier ook zegt dat hij
--    reiskosten declareert: claims_travel = false met een blijven staan getal is
--    anders stilzwijgend toch een claim.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.declaration_recompute(p_declaration_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_dec public.shift_declarations;
  v_c   RECORD;
BEGIN
  SELECT * INTO v_dec FROM public.shift_declarations WHERE id = p_declaration_id;
  IF NOT FOUND THEN RETURN; END IF;

  SELECT * INTO v_c FROM public.declaration_compute(
    v_dec.shift_id,
    CASE WHEN v_dec.claims_travel IS TRUE THEN v_dec.own_car_km END
  );

  UPDATE public.shift_declarations
     SET computed_distance_km     = v_c.distance_km,
         computed_reimbursable_km = v_c.reimbursable_km,
         computed_rule            = v_c.rule,
         rate_id                  = v_c.rate_id,
         computed_pharmacy_id     = v_c.pharmacy_id,
         computed_incomplete      = v_c.incomplete,
         computed_reason          = v_c.reason
   WHERE id = p_declaration_id;
END;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 10. RLS — dicht.
--     shift_declarations bevat token-hashes en de invoer van koeriers. Er komt
--     GEEN policy voor anon of authenticated: de invulpagina praat uitsluitend
--     met een Edge Function (SECURITY DEFINER, service-role) en het plannerscherm
--     leest via de functies uit migratie 019. Zonder policy weigert RLS alles,
--     ook voor een ingelogde planner — dat is hier precies de bedoeling.
--
--     courier_distances en reimbursement_rates zijn geen geheim tegenover een
--     planner en krijgen wél een leespolicy, zodat het beheerscherm ze
--     rechtstreeks kan tonen (zelfde keuze als courier_announcements in 016).
--     Schrijven gebeurt ook daar uitsluitend via de functies.
-- ────────────────────────────────────────────────────────────────────────
ALTER TABLE public.shift_declarations  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.courier_distances   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reimbursement_rates ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.shift_declarations FROM PUBLIC, anon, authenticated;

DROP POLICY IF EXISTS "distances_privileged_read" ON public.courier_distances;
CREATE POLICY "distances_privileged_read" ON public.courier_distances
  FOR SELECT USING (public.is_privileged());

DROP POLICY IF EXISTS "rates_privileged_read" ON public.reimbursement_rates;
CREATE POLICY "rates_privileged_read" ON public.reimbursement_rates
  FOR SELECT USING (public.is_privileged());

-- Een policy alleen is niet genoeg. Nieuwe tabellen krijgen in de huidige
-- Supabase-instelling géén rechten voor anon/authenticated (auto_expose staat
-- uit, zie supabase/config.toml), en dan loopt de planner op "permission denied"
-- vóór de policy überhaupt bekeken wordt. SELECT expliciet toekennen; de policy
-- doet daarna het echte werk en houdt niet-planners buiten.
GRANT SELECT ON public.courier_distances   TO authenticated;
GRANT SELECT ON public.reimbursement_rates TO authenticated;

-- De Edge Function courier-distances schrijft de berekende afstanden als
-- service-role rechtstreeks weg (geen SECURITY DEFINER-functie ertussen, want er
-- valt niets te beslissen). Om dezelfde reden als hierboven moet dat recht
-- expliciet toegekend worden.
GRANT SELECT, INSERT, UPDATE ON public.courier_distances TO service_role;
GRANT SELECT                  ON public.reimbursement_rates TO service_role;


-- ────────────────────────────────────────────────────────────────────────
-- 11. Wat de planner mag — via functies, niet via de tabel.
--     De standplaats staat op user_profiles, een tabel van de bezorg-app met
--     eigen kolomrechten. Die rechten uitbreiden zou het profiel van élke
--     gebruiker raken; een functie met een is_privileged()-controle raakt alleen
--     wat hij zelf doet.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.courier_home_overview()
RETURNS TABLE (
  courier_id       UUID,
  courier_name     TEXT,
  home_pharmacy_id TEXT,
  distances        INT,
  computed_at      TIMESTAMPTZ
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT up.id, up.name, up.home_pharmacy_id,
         (SELECT count(*)::INT       FROM public.courier_distances cd WHERE cd.courier_id = up.id),
         (SELECT max(cd.computed_at) FROM public.courier_distances cd WHERE cd.courier_id = up.id)
  FROM public.user_profiles up
  WHERE up.role = 'courier'
    AND public.is_privileged()
  ORDER BY up.name;
$$;

CREATE OR REPLACE FUNCTION public.set_home_pharmacy(p_courier_id UUID, p_pharmacy_id TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'Alleen planners mogen de standplaats zetten.';
  END IF;

  UPDATE public.user_profiles
     SET home_pharmacy_id = p_pharmacy_id
   WHERE id = p_courier_id AND role = 'courier';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Geen koerier met id %.', p_courier_id;
  END IF;
END;
$$;

-- Een afstand met de hand zetten of corrigeren (source = 'manual'). Bedoeld voor
-- het geval de routeberekening niet lukt — bijvoorbeeld zolang een apotheek nog
-- geen adresgegevens heeft.
CREATE OR REPLACE FUNCTION public.set_courier_distance(
  p_courier_id UUID, p_pharmacy_id TEXT, p_distance_km NUMERIC
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'Alleen planners mogen afstanden zetten.';
  END IF;

  INSERT INTO public.courier_distances (courier_id, pharmacy_id, distance_km, source)
  VALUES (p_courier_id, p_pharmacy_id, p_distance_km, 'manual')
  ON CONFLICT (courier_id, pharmacy_id) DO UPDATE
    SET distance_km = EXCLUDED.distance_km,
        source      = 'manual',
        computed_at = now();
END;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 12. Rechten.
--     De rekenfuncties zijn voor de job (service_role); de beheerfuncties zijn
--     voor de ingelogde planner en controleren zelf op is_privileged().
--     EXECUTE staat standaard aan voor PUBLIC; dat moet er expliciet af, want
--     deze functies omzeilen als SECURITY DEFINER de RLS.
-- ────────────────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.declaration_compute(UUID, NUMERIC)        FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.declaration_recompute(UUID)               FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.declaration_new_token()                   FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.declaration_hash_token(TEXT)              FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.reimbursement_rate_on(TEXT, DATE)         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.courier_home_overview()                   FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_home_pharmacy(UUID, TEXT)             FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_courier_distance(UUID, TEXT, NUMERIC) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.declaration_compute(UUID, NUMERIC)        TO service_role;
GRANT EXECUTE ON FUNCTION public.declaration_recompute(UUID)               TO service_role;
GRANT EXECUTE ON FUNCTION public.reimbursement_rate_on(TEXT, DATE)         TO service_role;
GRANT EXECUTE ON FUNCTION public.courier_home_overview()                   TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_home_pharmacy(UUID, TEXT)             TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.set_courier_distance(UUID, TEXT, NUMERIC) TO authenticated, service_role;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie
--   1. de standplaatskolom staat er
--   2. er is een tarief voor beide vervoermiddelen
--   3. hoeveel apotheken hebben coördinaten — zonder die gegevens kan er geen
--      enkele afstand berekend worden (de bekende blokkade)
-- ────────────────────────────────────────────────────────────────────────
SELECT
  (SELECT count(*) FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'user_profiles'
      AND column_name = 'home_pharmacy_id')                       AS standplaats_kolom,
  (SELECT count(*) FROM public.reimbursement_rates)               AS tarieven,
  (SELECT count(*) FROM public.pharmacies)                        AS apotheken,
  (SELECT count(*) FROM public.pharmacies
    WHERE "addressLat" IS NOT NULL AND "addressLng" IS NOT NULL)  AS met_coordinaten;

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
