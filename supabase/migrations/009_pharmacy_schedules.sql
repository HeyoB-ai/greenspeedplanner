-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — roosters per apotheek — migratie 009
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Vaste, terugkerende diensten per apotheek. De generator maakt er concepten
-- ('draft') van in een meelopend venster; de bestaande bevestig-flow gaat
-- eroverheen. timing_reliable blijft default false.
-- ════════════════════════════════════════════════════════════════════════


-- ────────────────────────────────────────────────────────────────────────
-- 1. pharmacy_schedules — één regel per vaste dienst.
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.pharmacy_schedules (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pharmacy_id       TEXT NOT NULL REFERENCES public.pharmacies(id) ON DELETE CASCADE,
  weekday           SMALLINT NOT NULL CHECK (weekday BETWEEN 1 AND 7),  -- ISO: 1=maandag
  start_time        TIME NOT NULL,
  budgeted_end_time TIME,
  courier_id        UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,
  transport_mode    TEXT NOT NULL DEFAULT 'bike' CHECK (transport_mode IN ('bike', 'car')),
  car_is_own        BOOLEAN,
  CONSTRAINT pharmacy_schedules_car_chk CHECK (transport_mode <> 'car' OR car_is_own IS NOT NULL),
  start_date        DATE NOT NULL,
  end_date          DATE,
  is_active         BOOLEAN NOT NULL DEFAULT true,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by        UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS pharmacy_schedules_pharmacy_idx ON public.pharmacy_schedules (pharmacy_id);


-- ────────────────────────────────────────────────────────────────────────
-- 2. schedule_exceptions — datums die de planner bewust heeft overgeslagen,
--    zodat de generator ze niet opnieuw aanmaakt. Wordt gevuld door de app
--    bij een expliciete "verwijder dit concept"-actie (NIET door systeem-
--    opschoningen zoals deactiveren/hergenereren).
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.schedule_exceptions (
  schedule_id     UUID NOT NULL REFERENCES public.pharmacy_schedules(id) ON DELETE CASCADE,
  exception_date  DATE NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (schedule_id, exception_date)
);


-- ────────────────────────────────────────────────────────────────────────
-- 3. shifts: herkomst + idempotentie.
--    ON DELETE RESTRICT dwingt "deactiveren i.p.v. verwijderen" af: de DB
--    weigert een roosterregel te verwijderen zolang er diensten aan hangen,
--    zodat er geen zwevende concepten zonder herkomst ontstaan.
-- ────────────────────────────────────────────────────────────────────────
ALTER TABLE public.shifts
  ADD COLUMN IF NOT EXISTS schedule_id UUID REFERENCES public.pharmacy_schedules(id) ON DELETE RESTRICT;

CREATE UNIQUE INDEX IF NOT EXISTS shifts_schedule_date_uniq
  ON public.shifts (schedule_id, shift_date) WHERE schedule_id IS NOT NULL;


-- ────────────────────────────────────────────────────────────────────────
-- 4. holidays — officiële NL-feestdagen (geen werk). Goede Vrijdag en
--    Bevrijdingsdag bewust NIET opgenomen (dan wordt er gewoon gewerkt).
--    De vrijdag ná Hemelvaart staat er bewust NIET in → wordt gewerkt.
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.holidays (
  holiday_date  DATE PRIMARY KEY,
  name          TEXT NOT NULL
);

INSERT INTO public.holidays (holiday_date, name) VALUES
  ('2026-01-01','Nieuwjaarsdag'), ('2026-04-05','1e Paasdag'), ('2026-04-06','2e Paasdag'),
  ('2026-04-27','Koningsdag'), ('2026-05-14','Hemelvaartsdag'),
  ('2026-05-24','1e Pinksterdag'), ('2026-05-25','2e Pinksterdag'),
  ('2026-12-25','1e Kerstdag'), ('2026-12-26','2e Kerstdag'),
  ('2027-01-01','Nieuwjaarsdag'), ('2027-03-28','1e Paasdag'), ('2027-03-29','2e Paasdag'),
  ('2027-04-27','Koningsdag'), ('2027-05-06','Hemelvaartsdag'),
  ('2027-05-16','1e Pinksterdag'), ('2027-05-17','2e Pinksterdag'),
  ('2027-12-25','1e Kerstdag'), ('2027-12-26','2e Kerstdag'),
  ('2028-01-01','Nieuwjaarsdag'), ('2028-04-16','1e Paasdag'), ('2028-04-17','2e Paasdag'),
  ('2028-04-27','Koningsdag'), ('2028-05-25','Hemelvaartsdag'),
  ('2028-06-04','1e Pinksterdag'), ('2028-06-05','2e Pinksterdag'),
  ('2028-12-25','1e Kerstdag'), ('2028-12-26','2e Kerstdag')
ON CONFLICT (holiday_date) DO NOTHING;


-- ────────────────────────────────────────────────────────────────────────
-- 5. schedule_generation_state — één rij: t/m welke datum het venster gevuld
--    is. In de DB (niet localStorage) zodat het over planners/apparaten klopt.
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.schedule_generation_state (
  id             BOOLEAN PRIMARY KEY DEFAULT true CHECK (id),  -- singleton
  filled_through DATE,
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO public.schedule_generation_state (id) VALUES (true) ON CONFLICT DO NOTHING;


-- ────────────────────────────────────────────────────────────────────────
-- 6. Generator — maakt ontbrekende concepten in een meelopend venster.
--    Idempotent (ON CONFLICT op de partiële unieke index), slaat feestdagen en
--    exceptions over, en zet een vaste koerier alleen als die nog aan de
--    apotheek gekoppeld is (anders open). SECURITY DEFINER + planner-guard.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.generate_schedule_shifts(p_horizon_weeks INT DEFAULT 10)
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_today   DATE := current_date;
  v_end     DATE := current_date + (p_horizon_weeks * 7);
  v_created INT  := 0;
  r         RECORD;
  d         DATE;
  v_courier UUID;
  v_shift   UUID;
BEGIN
  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'Alleen planners mogen roosterdiensten genereren.';
  END IF;

  FOR r IN
    SELECT * FROM public.pharmacy_schedules
    WHERE is_active AND start_date <= v_end AND (end_date IS NULL OR end_date >= v_today)
  LOOP
    d := GREATEST(v_today, r.start_date);
    WHILE d <= LEAST(v_end, COALESCE(r.end_date, v_end)) LOOP
      IF EXTRACT(ISODOW FROM d)::INT = r.weekday
         AND NOT EXISTS (SELECT 1 FROM public.holidays h WHERE h.holiday_date = d)
         AND NOT EXISTS (SELECT 1 FROM public.schedule_exceptions e
                         WHERE e.schedule_id = r.id AND e.exception_date = d)
      THEN
        v_courier := r.courier_id;
        IF v_courier IS NOT NULL AND NOT EXISTS (
          SELECT 1 FROM public.courier_pharmacy_access c
          WHERE c.courier_id = v_courier AND c.pharmacy_id = r.pharmacy_id
        ) THEN
          v_courier := NULL;  -- koppeling vervallen → open aanmaken
        END IF;

        v_shift := NULL;
        INSERT INTO public.shifts
          (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
           status, transport_mode, car_is_own, timing_reliable, schedule_id, created_by)
        VALUES
          (v_courier, 'regular', d, r.start_time, r.budgeted_end_time,
           'draft', r.transport_mode, r.car_is_own, false, r.id, auth.uid())
        ON CONFLICT (schedule_id, shift_date) WHERE schedule_id IS NOT NULL DO NOTHING
        RETURNING id INTO v_shift;

        IF v_shift IS NOT NULL THEN
          INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id)
          VALUES (v_shift, r.pharmacy_id) ON CONFLICT DO NOTHING;
          v_created := v_created + 1;
        END IF;
      END IF;
      d := d + 1;
    END LOOP;
  END LOOP;

  UPDATE public.schedule_generation_state SET filled_through = v_end, updated_at = now() WHERE id;
  RETURN v_created;
END;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 7. RLS — planner-only config (is_privileged). Koeriers hebben geen toegang
--    tot de roostertabellen; gegenereerde diensten zien ze via de shifts-RLS.
-- ────────────────────────────────────────────────────────────────────────
ALTER TABLE public.pharmacy_schedules        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.schedule_exceptions       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.holidays                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.schedule_generation_state ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "schedules_privileged" ON public.pharmacy_schedules;
CREATE POLICY "schedules_privileged" ON public.pharmacy_schedules
  FOR ALL USING (public.is_privileged()) WITH CHECK (public.is_privileged());

DROP POLICY IF EXISTS "exceptions_privileged" ON public.schedule_exceptions;
CREATE POLICY "exceptions_privileged" ON public.schedule_exceptions
  FOR ALL USING (public.is_privileged()) WITH CHECK (public.is_privileged());

DROP POLICY IF EXISTS "holidays_privileged" ON public.holidays;
CREATE POLICY "holidays_privileged" ON public.holidays
  FOR ALL USING (public.is_privileged()) WITH CHECK (public.is_privileged());

DROP POLICY IF EXISTS "genstate_privileged" ON public.schedule_generation_state;
CREATE POLICY "genstate_privileged" ON public.schedule_generation_state
  FOR ALL USING (public.is_privileged()) WITH CHECK (public.is_privileged());
