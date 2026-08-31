-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — facturatie richting apotheken (fase 7) — migratie 025
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 018 t/m 024 eerst.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien, en draai daarna       │
-- │ supabase/tests/025_pharmacy_invoicing_test.sql.                        │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- Dit is een andere doorsnede dan fase 6. Die is gebouwd rond koerier en dienst;
-- deze rond klant en opdracht. declaration_compute(), declaration_overview() en
-- de mailketen worden hier NIET aangeraakt — er wordt alleen uit gelezen.
--
-- ┌─ EEN NAAM DIE AFWIJKT VAN DE OPDRACHT ─────────────────────────────────┐
-- │ De opdracht spreekt van shift_type = 'spoed'. Die waarde bestaat niet: │
-- │ migratie 001 legt vier types vast en de spoeddienst heet daar          │
-- │ 'urgent'. 'Spoed' is het Nederlandse label in de interface             │
-- │ (TYPE_STYLES.urgent.label). Hieronder staat overal 'urgent'.           │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- DE REKENREGELS
--   Uren        — naar rato van de geplande minuten per apotheek, in BEIDE
--                 richtingen: loopt de dienst uit, dan krijgt elke apotheek een
--                 evenredig deel van de uitloop; is de koerier eerder klaar, dan
--                 krijgt elke apotheek evenredig minder. Geen ondergrens, geen
--                 plafond. Bij één apotheek gaat de volledige duur daarheen.
--   Starttarief — NIET naar rato. Elke apotheek in de dienst krijgt een volledig
--                 starttarief tegen haar eigen tarief: voor die apotheek is het
--                 een aparte opdracht, ongeacht waar de koerier verder langsging.
--   Reiskosten  — wél naar rato, op dezelfde verhouding als de uren.
--   Spoed       — een vrij bedrag dat de planner invoert; telefonisch afgesproken
--                 en dus niet uit een tarieventabel. Dan telt ALLEEN dat bedrag:
--                 geen uren, geen starttarief, geen reiskosten. De koerier krijgt
--                 zijn uren gewoon via de declaratieketen; dat staat hier los van.
--
--   Ontbreekt de declaratie, de verhouding of het tarief, dan wordt de regel
--   berekend met wat er wél is en gemarkeerd — nooit stilzwijgend aangenomen.
--   Zelfde lijn als declaration_compute() in migratie 018.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────
-- 1. Geplande minuten per apotheek per dienst — de ontbrekende schakel.
--    shift_pharmacies legt vast wélke apotheken bij een dienst horen, niet
--    hoeveel tijd elk krijgt. Zonder die verhouding is er niets naar rato te
--    verdelen.
--
--    Nullable: bestaande rijen hebben het niet, en de tabel is gedeeld met de
--    bezorg-app en AIrouteplanner. Ontbreekt de waarde bij een dienst met
--    meerdere apotheken, dan verdeelt invoice_lines() gelijk en markeert de regel.
--
--    De CHECK staat als losse, genoemde constraint. ADD COLUMN IF NOT EXISTS
--    slaat het hele statement over zodra de kolom bestaat; een inline CHECK zou
--    dan stilzwijgend ontbreken. Zelfde les als bij de standplaats in 024.
-- ────────────────────────────────────────────────────────────────────────
ALTER TABLE public.shift_pharmacies
  ADD COLUMN IF NOT EXISTS budgeted_minutes INTEGER;

ALTER TABLE public.shift_pharmacies
  DROP CONSTRAINT IF EXISTS shift_pharmacies_budgeted_minutes_check;

ALTER TABLE public.shift_pharmacies
  ADD CONSTRAINT shift_pharmacies_budgeted_minutes_check
  CHECK (budgeted_minutes IS NULL OR budgeted_minutes > 0);

COMMENT ON COLUMN public.shift_pharmacies.budgeted_minutes IS
  'Geplande minuten voor déze apotheek binnen de dienst (migratie 025). Bepaalt '
  'de verhouding waarmee de werkelijke duur en de reiskosten over de apotheken '
  'verdeeld worden. NULL = niet vastgelegd; dan verdeelt invoice_lines() gelijk '
  'en markeert de regel.';


-- ────────────────────────────────────────────────────────────────────────
-- 2. Tarieven per apotheek, met ingangsdatum.
--    Zelfde patroon en dezelfde reden als reimbursement_rates (migratie 018):
--    een oude factuur moet later nog met het toen geldende tarief te herleiden
--    zijn. Een tariefwijziging is dus een INSERT met een nieuwe effective_from,
--    nooit een UPDATE van een bestaande rij.
--    pharmacy_id is TEXT — pharmacies.id is dat ook (migratie 001).
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.pharmacy_rates (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id    TEXT NOT NULL REFERENCES public.pharmacies(id) ON DELETE CASCADE,
  hourly_rate    NUMERIC(8,2) NOT NULL CHECK (hourly_rate >= 0),
  start_rate     NUMERIC(8,2) NOT NULL DEFAULT 0 CHECK (start_rate >= 0),
  effective_from DATE NOT NULL,
  note           TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (pharmacy_id, effective_from)
);

CREATE INDEX IF NOT EXISTS pharmacy_rates_lookup_idx
  ON public.pharmacy_rates (pharmacy_id, effective_from DESC);

-- Er worden bewust GEEN starttarieven ingevuld. Anders dan bij de
-- kilometervergoeding is er geen landelijk getal om op terug te vallen, en een
-- verzonnen tarief dat er plausibel uitziet is hier het gevaarlijkst: dat merk
-- je pas als de factuur de deur uit is. Geen rij = geen tarief = zichtbaar
-- onvolledige factuurregel.


-- ────────────────────────────────────────────────────────────────────────
-- 3. Spoedbedrag op de dienst.
--    Vrij bedrag plus toelichting, want dit wordt telefonisch afgesproken.
-- ────────────────────────────────────────────────────────────────────────
ALTER TABLE public.shifts
  ADD COLUMN IF NOT EXISTS urgent_amount NUMERIC(8,2);
ALTER TABLE public.shifts
  ADD COLUMN IF NOT EXISTS urgent_note TEXT;

ALTER TABLE public.shifts
  DROP CONSTRAINT IF EXISTS shifts_urgent_amount_check;
ALTER TABLE public.shifts
  ADD CONSTRAINT shifts_urgent_amount_check
  CHECK (urgent_amount IS NULL OR urgent_amount >= 0);

COMMENT ON COLUMN public.shifts.urgent_amount IS
  'Telefonisch afgesproken bedrag voor een spoeddienst (shift_type = urgent, '
  'migratie 025). Bij spoed is dit het HELE factuurbedrag richting de apotheek.';

-- Beide velden horen alleen bij een spoeddienst. Dit kan geen CHECK zijn met een
-- nette foutmelding over het type erbij, en het moet ook standhouden als iemand
-- het type later terugzet — vandaar een trigger, in de stijl van
-- declaration_check_own_car() uit migratie 018.
--
-- Let op: shifts is gedeeld met de bezorg-app en AIrouteplanner. Deze trigger
-- doet niets zolang beide kolommen leeg zijn, dus voor die apps verandert er
-- niets; ze bestaan niet eens van deze velden.
CREATE OR REPLACE FUNCTION public.shift_check_urgent()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.urgent_amount IS NULL AND NEW.urgent_note IS NULL THEN
    RETURN NEW;
  END IF;

  IF NEW.shift_type <> 'urgent' THEN
    RAISE EXCEPTION
      'Spoedbedrag en spoedtoelichting horen alleen bij een spoeddienst (type is nu %).',
      NEW.shift_type;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS shifts_urgent_chk ON public.shifts;
CREATE TRIGGER shifts_urgent_chk
  BEFORE INSERT OR UPDATE OF urgent_amount, urgent_note, shift_type ON public.shifts
  FOR EACH ROW EXECUTE FUNCTION public.shift_check_urgent();


-- ────────────────────────────────────────────────────────────────────────
-- 4. invoice_settings — één rij met wat instelbaar moet zijn.
--    deviation_pct is de grens waarboven een afwijking tussen gepland en
--    werkelijk gemeld wordt. Een signaal, geen afkeuring: bij één apotheek in de
--    dienst gaat een uitloop volledig naar die klant, en een factuur die
--    verdubbelt door een invoerfout wil je zien vóór je hem verstuurt.
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.invoice_settings (
  id            BOOLEAN PRIMARY KEY DEFAULT true CHECK (id),
  deviation_pct INTEGER NOT NULL DEFAULT 25 CHECK (deviation_pct > 0)
);

INSERT INTO public.invoice_settings (id) VALUES (true) ON CONFLICT DO NOTHING;


-- ────────────────────────────────────────────────────────────────────────
-- 5. Het tarief dat gold op een datum. Dezelfde opzoekvorm als
--    reimbursement_rate_on() (migratie 018): de jongste ingangsdatum die niet ná
--    de dienstdatum ligt.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.pharmacy_rate_on(p_pharmacy_id TEXT, p_date DATE)
RETURNS public.pharmacy_rates
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT r.* FROM public.pharmacy_rates r
  WHERE r.pharmacy_id = p_pharmacy_id
    AND r.effective_from <= p_date
  ORDER BY r.effective_from DESC
  LIMIT 1;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 6. invoice_lines — de berekening.
--
--    Eén regel per (dienst, deze apotheek). Géén aannames over een
--    exportformaat: dit is een berekening, geen bestandsgenerator. Wat er met de
--    bedragen richting een boekhoudpakket gebeurt is nog niet bepaald, en deze
--    functie hoeft dat niet te weten.
--
--    Concepten (status 'draft') tellen niet mee: die zijn niet bevestigd en dus
--    geen opdracht. Alles wat wél bevestigd is telt, ongeacht of de koerier al
--    ingevuld heeft.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.invoice_lines(
  p_pharmacy_id TEXT, p_from DATE, p_to DATE
)
RETURNS TABLE (
  shift_id              UUID,
  shift_date            DATE,
  shift_type            TEXT,
  courier_name          TEXT,
  pharmacies_in_shift   INT,
  planned_minutes       INT,      -- voor déze apotheek
  share_pct             NUMERIC,  -- aandeel in het totaal, in procenten
  shift_planned_minutes INT,      -- geplande duur van de hele dienst
  shift_actual_minutes  INT,      -- werkelijke duur uit de declaratie
  billed_minutes        NUMERIC,  -- wat er van die duur naar deze apotheek gaat
  from_declaration      BOOLEAN,  -- false = op geplande uren gefactureerd
  hourly_rate           NUMERIC,
  rate_id               UUID,
  hours_amount          NUMERIC,
  start_amount          NUMERIC,
  travel_amount         NUMERIC,
  urgent_amount         NUMERIC,
  urgent_note           TEXT,
  line_total            NUMERIC,
  incomplete            BOOLEAN,
  reason                TEXT
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cfg      public.invoice_settings;
  r          RECORD;
  v_rate     public.pharmacy_rates;
  v_reasons  TEXT[];
  v_n        INT;
  v_sum      INT;
  v_missing  BOOLEAN;
  v_share    NUMERIC;
  v_planned  INT;      -- geplande duur van de dienst
  v_actual   INT;      -- werkelijke duur uit de declaratie
  v_minutes  NUMERIC;  -- wat er gefactureerd wordt, vóór verdeling
  v_billed   NUMERIC;
  v_travel   NUMERIC;
  v_dev      NUMERIC;
BEGIN
  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'Alleen planners mogen factuurregels opvragen.';
  END IF;

  SELECT * INTO v_cfg FROM public.invoice_settings WHERE id;

  FOR r IN
    SELECT s.id, s.shift_date, s.shift_type, s.start_time, s.budgeted_end_time,
           s.urgent_amount, s.urgent_note,
           up.name AS courier_name,
           sp.budgeted_minutes,
           (SELECT count(*) FROM public.shift_pharmacies x WHERE x.shift_id = s.id) AS n_pharmacies,
           (SELECT sum(x.budgeted_minutes) FROM public.shift_pharmacies x WHERE x.shift_id = s.id) AS sum_minutes,
           EXISTS (SELECT 1 FROM public.shift_pharmacies x
                    WHERE x.shift_id = s.id AND x.budgeted_minutes IS NULL) AS any_missing,
           d.actual_start, d.actual_end, d.claims_travel,
           d.computed_reimbursable_km, rr.rate_per_km
    FROM public.shift_pharmacies sp
    JOIN public.shifts s              ON s.id = sp.shift_id
    LEFT JOIN public.user_profiles up ON up.id = s.courier_id
    LEFT JOIN public.shift_declarations d ON d.shift_id = s.id
    LEFT JOIN public.reimbursement_rates rr ON rr.id = d.rate_id
    WHERE sp.pharmacy_id = p_pharmacy_id
      AND s.status <> 'draft'
      AND (p_from IS NULL OR s.shift_date >= p_from)
      AND (p_to   IS NULL OR s.shift_date <= p_to)
    ORDER BY s.shift_date, s.start_time
  LOOP
    v_reasons := ARRAY[]::TEXT[];
    v_n       := r.n_pharmacies;
    v_sum     := r.sum_minutes;
    v_missing := r.any_missing;

    -- ── Het aandeel van deze apotheek ──────────────────────────────────
    IF v_n <= 1 THEN
      -- Eén apotheek: alles gaat daarheen. Een ontbrekende budgeted_minutes doet
      -- er dan niet toe — er valt niets te verdelen.
      v_share := 1;
    ELSIF v_missing OR v_sum IS NULL OR v_sum = 0 THEN
      -- Bij een dienst met meerdere apotheken is de verhouding onbekend zodra er
      -- één ontbreekt: de som klopt dan niet meer. Gelijk verdelen en melden.
      v_share := 1::NUMERIC / v_n;
      v_reasons := v_reasons || format(
        'geen geplande minuten vastgelegd; gelijk verdeeld over %s apotheken', v_n);
    ELSE
      v_share := r.budgeted_minutes::NUMERIC / v_sum;
    END IF;

    -- ── Duur: gepland en werkelijk ─────────────────────────────────────
    v_planned := CASE WHEN r.budgeted_end_time IS NULL THEN NULL ELSE
      (EXTRACT(EPOCH FROM (r.budgeted_end_time - r.start_time
        + CASE WHEN r.budgeted_end_time <= r.start_time THEN INTERVAL '1 day' ELSE INTERVAL '0' END)) / 60)::INT
    END;

    v_actual := CASE WHEN r.actual_start IS NULL OR r.actual_end IS NULL THEN NULL ELSE
      (EXTRACT(EPOCH FROM (r.actual_end - r.actual_start
        + CASE WHEN r.actual_end <= r.actual_start THEN INTERVAL '1 day' ELSE INTERVAL '0' END)) / 60)::INT
    END;

    IF v_actual IS NULL THEN
      -- Geen ingevulde declaratie. De factuur wordt hier niet door opgehouden:
      -- de geplande uren gaan mee, met een markering dat het een aanname is.
      v_minutes := v_planned;
      IF v_planned IS NULL THEN
        v_reasons := v_reasons || 'geen ingevulde declaratie en geen geplande eindtijd';
      ELSE
        v_reasons := v_reasons || 'geen ingevulde declaratie; geplande uren gefactureerd';
      END IF;
    ELSE
      v_minutes := v_actual;
      -- Wijkt de werkelijke duur ver af van de planning, dan is dat een signaal
      -- en geen afkeuring. Zie de opmerking bij invoice_settings.
      IF v_planned IS NOT NULL AND v_planned > 0 THEN
        v_dev := abs(v_actual - v_planned)::NUMERIC / v_planned * 100;
        IF v_dev > v_cfg.deviation_pct THEN
          v_reasons := v_reasons || format(
            'werkelijke duur wijkt %s%% af van gepland (%s vs %s minuten)',
            round(v_dev), v_actual, v_planned);
        END IF;
      END IF;
    END IF;

    v_billed := round(COALESCE(v_minutes, 0) * v_share, 2);

    -- ── Tarief ─────────────────────────────────────────────────────────
    -- Wel opzoeken, nog niet melden: bij spoed doet het tarief niet mee en zou
    -- "geen tarief" een melding zijn over iets wat niet gebruikt wordt.
    v_rate := public.pharmacy_rate_on(p_pharmacy_id, r.shift_date);

    -- ── Reiskosten, naar rato ──────────────────────────────────────────
    v_travel := CASE
      WHEN r.claims_travel IS TRUE AND r.computed_reimbursable_km IS NOT NULL AND r.rate_per_km IS NOT NULL
      THEN round(r.computed_reimbursable_km * r.rate_per_km * v_share, 2)
      ELSE 0
    END;

    -- ── De regel ───────────────────────────────────────────────────────
    shift_id              := r.id;
    shift_date            := r.shift_date;
    shift_type            := r.shift_type;
    courier_name          := r.courier_name;
    pharmacies_in_shift   := v_n;
    planned_minutes       := COALESCE(r.budgeted_minutes, round(COALESCE(v_planned, 0) * v_share)::INT);
    share_pct             := round(v_share * 100, 1);
    shift_planned_minutes := v_planned;
    shift_actual_minutes  := v_actual;
    billed_minutes        := v_billed;
    from_declaration      := v_actual IS NOT NULL;
    rate_id               := v_rate.id;
    urgent_note           := r.urgent_note;

    IF r.shift_type = 'urgent' THEN
      -- Spoed: alleen het afgesproken bedrag. Geen uren, geen starttarief, geen
      -- reiskosten — "alleen dat bedrag", en de koerier wordt los daarvan
      -- betaald via de declaratieketen. De uren blijven wél in de regel staan
      -- (billed_minutes), zodat zichtbaar is waar het bedrag tegenover staat.
      hourly_rate   := NULL;
      hours_amount  := NULL;
      start_amount  := NULL;
      travel_amount := NULL;
      urgent_amount := r.urgent_amount;
      line_total    := r.urgent_amount;

      -- De meldingen die tot hier verzameld zijn gaan allemaal over uren: geen
      -- declaratie, een onbekende verhouding, een afwijking van de planning. Bij
      -- spoed raakt geen daarvan het factuurbedrag, en een markering op een regel
      -- die gewoon klopt leert de planner de markering te negeren. Alleen het
      -- ontbrekende bedrag telt hier.
      v_reasons := ARRAY[]::TEXT[];
      IF r.urgent_amount IS NULL THEN
        v_reasons := v_reasons || 'spoedbedrag nog niet ingevuld';
      END IF;
    ELSE
      IF v_rate.id IS NULL THEN
        v_reasons := v_reasons || format('geen tarief voor deze apotheek op %s', r.shift_date);
      END IF;
      hourly_rate   := v_rate.hourly_rate;
      -- Het starttarief wordt NIET verdeeld: elke apotheek is een eigen opdracht.
      start_amount  := v_rate.start_rate;
      hours_amount  := CASE WHEN v_rate.id IS NULL THEN NULL
                            ELSE round(v_billed / 60 * v_rate.hourly_rate, 2) END;
      travel_amount := v_travel;
      urgent_amount := NULL;
      line_total    := CASE WHEN v_rate.id IS NULL THEN NULL
                            ELSE COALESCE(hours_amount, 0) + COALESCE(start_amount, 0) + COALESCE(v_travel, 0) END;
    END IF;

    incomplete := array_length(v_reasons, 1) IS NOT NULL;
    reason     := CASE WHEN incomplete THEN array_to_string(v_reasons, '; ') END;
    RETURN NEXT;
  END LOOP;
END;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 7. Tariefbeheer — schrijven via een functie, met een is_privileged()-controle.
--    Dezelfde effective_from opnieuw invoeren corrigeert die rij; een nieuwe
--    datum is een tariefwijziging en laat de oude staan.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_pharmacy_rate(
  p_pharmacy_id TEXT, p_hourly_rate NUMERIC, p_start_rate NUMERIC,
  p_effective_from DATE, p_note TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id UUID;
BEGIN
  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'Alleen planners mogen tarieven zetten.';
  END IF;

  INSERT INTO public.pharmacy_rates (pharmacy_id, hourly_rate, start_rate, effective_from, note)
  VALUES (p_pharmacy_id, p_hourly_rate, COALESCE(p_start_rate, 0), p_effective_from,
          NULLIF(btrim(COALESCE(p_note, '')), ''))
  ON CONFLICT (pharmacy_id, effective_from) DO UPDATE
    SET hourly_rate = EXCLUDED.hourly_rate,
        start_rate  = EXCLUDED.start_rate,
        note        = EXCLUDED.note
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- Een tariefrij weghalen. Alleen voor een verkeerd ingevoerde rij; een tarief
-- dat echt gegolden heeft laat je staan, want oude facturen verwijzen ernaar.
CREATE OR REPLACE FUNCTION public.delete_pharmacy_rate(p_rate_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'Alleen planners mogen tarieven verwijderen.';
  END IF;
  DELETE FROM public.pharmacy_rates WHERE id = p_rate_id;
END;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 8. RLS en rechten.
--    Tarieven en instellingen zijn geen geheim tegenover een planner en krijgen
--    een leespolicy; schrijven loopt via de functies hierboven. Zelfde opzet als
--    reimbursement_rates in migratie 018, inclusief de expliciete GRANT: nieuwe
--    tabellen krijgen in de huidige Supabase-instelling geen rechten voor
--    authenticated, en dan struikelt de planner op "permission denied" nog vóór
--    de policy bekeken wordt.
-- ────────────────────────────────────────────────────────────────────────
ALTER TABLE public.pharmacy_rates   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.invoice_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "pharmacy_rates_privileged_read" ON public.pharmacy_rates;
CREATE POLICY "pharmacy_rates_privileged_read" ON public.pharmacy_rates
  FOR SELECT USING (public.is_privileged());

DROP POLICY IF EXISTS "invoice_settings_privileged_read" ON public.invoice_settings;
CREATE POLICY "invoice_settings_privileged_read" ON public.invoice_settings
  FOR SELECT USING (public.is_privileged());

GRANT SELECT ON public.pharmacy_rates   TO authenticated;
GRANT SELECT ON public.invoice_settings TO authenticated;

-- budgeted_minutes moet door de dienstdialoog geschreven kunnen worden. De
-- planner heeft al INSERT/UPDATE op shift_pharmacies via de policies van
-- migratie 001; staan er kolomrechten in de weg, dan zet dit het recht op deze
-- ene kolom alsnog. Op een tabelrecht is dit een no-op.
GRANT SELECT (budgeted_minutes), INSERT (budgeted_minutes), UPDATE (budgeted_minutes)
  ON public.shift_pharmacies TO authenticated;

-- Idem voor de twee spoedvelden op shifts.
GRANT SELECT (urgent_amount, urgent_note), INSERT (urgent_amount, urgent_note),
      UPDATE (urgent_amount, urgent_note)
  ON public.shifts TO authenticated;

REVOKE ALL     ON FUNCTION public.invoice_lines(TEXT, DATE, DATE)                     FROM PUBLIC, anon;
REVOKE ALL     ON FUNCTION public.pharmacy_rate_on(TEXT, DATE)                        FROM PUBLIC, anon, authenticated;
REVOKE ALL     ON FUNCTION public.set_pharmacy_rate(TEXT, NUMERIC, NUMERIC, DATE, TEXT) FROM PUBLIC, anon;
REVOKE ALL     ON FUNCTION public.delete_pharmacy_rate(UUID)                          FROM PUBLIC, anon;

GRANT  EXECUTE ON FUNCTION public.invoice_lines(TEXT, DATE, DATE)                     TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.pharmacy_rate_on(TEXT, DATE)                        TO service_role;
GRANT  EXECUTE ON FUNCTION public.set_pharmacy_rate(TEXT, NUMERIC, NUMERIC, DATE, TEXT) TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.delete_pharmacy_rate(UUID)                          TO authenticated, service_role;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie
--   1. de drie schema-wijzigingen staan er
--   2. hoeveel diensten met meerdere apotheken missen nog een verhouding —
--      dat is precies de lijst die anders gelijk verdeeld wordt
--   3. voor hoeveel apotheken is er nog geen tarief
-- ────────────────────────────────────────────────────────────────────────
SELECT
  (SELECT count(*) FROM information_schema.columns
    WHERE table_schema='public' AND table_name='shift_pharmacies' AND column_name='budgeted_minutes') AS kolom_minuten,
  (SELECT count(*) FROM information_schema.columns
    WHERE table_schema='public' AND table_name='shifts' AND column_name='urgent_amount')             AS kolom_spoed,
  (SELECT count(*) FROM public.pharmacy_rates)                                                        AS tarieven,
  (SELECT deviation_pct FROM public.invoice_settings WHERE id)                                        AS afwijkingsgrens_pct;

SELECT s.shift_date, s.id AS dienst, count(*) AS apotheken
FROM public.shifts s
JOIN public.shift_pharmacies sp ON sp.shift_id = s.id
WHERE s.status <> 'draft'
GROUP BY s.id, s.shift_date
HAVING count(*) > 1 AND bool_or(sp.budgeted_minutes IS NULL)
ORDER BY s.shift_date DESC
LIMIT 20;

SELECT p.id, p.name
FROM public.pharmacies p
WHERE NOT EXISTS (SELECT 1 FROM public.pharmacy_rates r WHERE r.pharmacy_id = p.id)
ORDER BY p.name;

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
