-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — tijdregistratie per dienst — migratie 005
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Volgt de conventies van migratie 001: TEXT + CHECK, IF NOT EXISTS, expliciete
-- RLS, hergebruik van is_privileged().
--
-- Eén rij per dienst. Ruwe meting, berekend voorstel en bevestiging staan apart,
-- zodat elke uitkomst herleidbaar blijft. De berekende tijd is een VOORSTEL.
-- ════════════════════════════════════════════════════════════════════════


-- ────────────────────────────────────────────────────────────────────────
-- 1. shifts: onderscheid eigen auto vs. bedrijfsauto.
--    Alleen betekenisvol bij transport_mode = 'car'. GEEN default false: dan
--    is "planner is het vergeten" niet te onderscheiden van "bedrijfsauto" en
--    verdwijnen kilometers stilzwijgend.
--    De CHECK staat NOT VALID: bestaande rijen worden gegrandfatherd (een
--    productietabel kan al 'car'-diensten zonder keuze bevatten), maar élke
--    nieuwe of gewijzigde rij moet voldoen.
-- ────────────────────────────────────────────────────────────────────────
ALTER TABLE public.shifts
  ADD COLUMN IF NOT EXISTS car_is_own boolean;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'shifts_car_is_own_chk'
  ) THEN
    ALTER TABLE public.shifts
      ADD CONSTRAINT shifts_car_is_own_chk
      CHECK (transport_mode <> 'car' OR car_is_own IS NOT NULL) NOT VALID;
  END IF;
END $$;


-- ────────────────────────────────────────────────────────────────────────
-- 2. shift_time_reports — één rij per dienst.
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.shift_time_reports (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  shift_id          UUID NOT NULL UNIQUE REFERENCES public.shifts(id) ON DELETE CASCADE,

  -- Ruwe meting uit de scandata.
  first_scan_at     TIMESTAMPTZ,
  last_scan_at      TIMESTAMPTZ,
  last_scan_lat     NUMERIC,
  last_scan_lng     NUMERIC,

  -- Berekend voorstel.
  computed_start    TIMESTAMPTZ,
  computed_end      TIMESTAMPTZ,
  calc_details      JSONB,          -- marges, afstand, snelheid, aantal trajecten,
                                    -- fallbackniveau, gaten, modelversie

  -- Door de koerier bevestigd/gecorrigeerd.
  confirmed_start   TIMESTAMPTZ,
  confirmed_end     TIMESTAMPTZ,
  courier_comment   TEXT,
  own_car_km        NUMERIC,        -- alleen bij eigen auto

  status            TEXT NOT NULL DEFAULT 'computed'
                    CHECK (status IN
                      ('computed','sent','confirmed','adjusted','approved','disputed')),
  dispute_reason    TEXT,

  confirmed_at      TIMESTAMPTZ,
  approved_at       TIMESTAMPTZ,
  approved_by       UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- ────────────────────────────────────────────────────────────────────────
-- 3. RLS
-- ────────────────────────────────────────────────────────────────────────
-- Koerier: leest ALLEEN de rij van zijn eigen dienst en mag alleen
-- confirmed_start/confirmed_end/courier_comment/own_car_km zetten zolang de
-- status niet 'approved' is. De kolom-beperking wordt met een trigger bewaakt
-- (RLS-policies werken per rij, niet per kolom). Planners (is_privileged) mogen
-- alles. Het systeem (compute-script) draait als service_role en omzeilt RLS.
-- ────────────────────────────────────────────────────────────────────────
ALTER TABLE public.shift_time_reports ENABLE ROW LEVEL SECURITY;

-- Lezen.
DROP POLICY IF EXISTS "str_select" ON public.shift_time_reports;
CREATE POLICY "str_select" ON public.shift_time_reports
  FOR SELECT
  USING (
    public.is_privileged()
    OR EXISTS (
      SELECT 1 FROM public.shifts s
      WHERE s.id = shift_time_reports.shift_id
        AND s.courier_id = auth.uid()
    )
  );

-- Aanmaken: alleen planners (systeem = service_role, omzeilt RLS).
DROP POLICY IF EXISTS "str_insert" ON public.shift_time_reports;
CREATE POLICY "str_insert" ON public.shift_time_reports
  FOR INSERT
  WITH CHECK (public.is_privileged());

-- Wijzigen: planners altijd; koerier enkel eigen rij zolang niet 'approved'.
-- De WITH CHECK verhindert dat de koerier de rij naar 'approved' tilt of aan een
-- andere dienst hangt; de trigger bewaakt welke kolommen mogen wijzigen.
DROP POLICY IF EXISTS "str_update" ON public.shift_time_reports;
CREATE POLICY "str_update" ON public.shift_time_reports
  FOR UPDATE
  USING (
    public.is_privileged()
    OR (
      EXISTS (
        SELECT 1 FROM public.shifts s
        WHERE s.id = shift_time_reports.shift_id
          AND s.courier_id = auth.uid()
      )
      AND status <> 'approved'
    )
  )
  WITH CHECK (
    public.is_privileged()
    OR (
      EXISTS (
        SELECT 1 FROM public.shifts s
        WHERE s.id = shift_time_reports.shift_id
          AND s.courier_id = auth.uid()
      )
      AND status <> 'approved'
    )
  );

-- Verwijderen: alleen planners.
DROP POLICY IF EXISTS "str_delete" ON public.shift_time_reports;
CREATE POLICY "str_delete" ON public.shift_time_reports
  FOR DELETE
  USING (public.is_privileged());


-- ────────────────────────────────────────────────────────────────────────
-- 4. Kolom-beperking voor de koerier (trigger).
--    Systeem (service_role) en planners mogen alles. Een gewone ingelogde
--    gebruiker (de koerier) mag ALLEEN confirmed_start, confirmed_end,
--    courier_comment en own_car_km wijzigen, en niets aan een 'approved' rij.
--    computed_* en status='approved' zijn zo voor de koerier onbereikbaar.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.enforce_str_courier_limits()
RETURNS trigger AS $$
BEGIN
  IF auth.role() = 'service_role' OR public.is_privileged() THEN
    RETURN NEW;
  END IF;

  IF OLD.status = 'approved' THEN
    RAISE EXCEPTION 'Goedgekeurde tijdregistratie kan niet meer gewijzigd worden.';
  END IF;

  IF NEW.id             IS DISTINCT FROM OLD.id
     OR NEW.shift_id       IS DISTINCT FROM OLD.shift_id
     OR NEW.first_scan_at  IS DISTINCT FROM OLD.first_scan_at
     OR NEW.last_scan_at   IS DISTINCT FROM OLD.last_scan_at
     OR NEW.last_scan_lat  IS DISTINCT FROM OLD.last_scan_lat
     OR NEW.last_scan_lng  IS DISTINCT FROM OLD.last_scan_lng
     OR NEW.computed_start IS DISTINCT FROM OLD.computed_start
     OR NEW.computed_end   IS DISTINCT FROM OLD.computed_end
     OR NEW.calc_details   IS DISTINCT FROM OLD.calc_details
     OR NEW.status         IS DISTINCT FROM OLD.status
     OR NEW.dispute_reason IS DISTINCT FROM OLD.dispute_reason
     OR NEW.confirmed_at   IS DISTINCT FROM OLD.confirmed_at
     OR NEW.approved_at    IS DISTINCT FROM OLD.approved_at
     OR NEW.approved_by    IS DISTINCT FROM OLD.approved_by
     OR NEW.created_at     IS DISTINCT FROM OLD.created_at THEN
    RAISE EXCEPTION 'Koerier mag alleen confirmed_start, confirmed_end, courier_comment en own_car_km wijzigen.';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_str_courier_limits ON public.shift_time_reports;
CREATE TRIGGER trg_str_courier_limits
  BEFORE UPDATE ON public.shift_time_reports
  FOR EACH ROW EXECUTE FUNCTION public.enforce_str_courier_limits();

-- Index voor het plannerscherm (openstaande/afwijkende rijen per status).
CREATE INDEX IF NOT EXISTS shift_time_reports_status_idx
  ON public.shift_time_reports (status);
