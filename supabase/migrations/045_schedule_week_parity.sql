-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — roosterregels per even of oneven week — 045
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 009 eerst (die maakte pharmacy_schedules en de generator).
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien.                       │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAAROM
--   Een roosterregel gold tot nu toe iedere week. Apotheken die om de week
--   bezorgen moesten daarvoor twee regels aanmaken en telkens met de hand de
--   verkeerde week weer als uitzondering wegstrepen. Met week_parity staat het
--   ritme in de regel zelf.
--
-- 'BOTH' ALS STANDAARD
--   Bestaande regels moeten precies blijven doen wat ze deden. NOT NULL DEFAULT
--   'both' zorgt dat elke bestaande rij ongewijzigd elke week blijft draaien;
--   zonder die default zou een NULL de generator stil laten overslaan.
--
-- LET OP — DE PARITEIT VOLGT HET ISO-WEEKNUMMER
--   Even of oneven wordt per kalenderjaar bepaald uit EXTRACT(WEEK), het ISO-
--   weeknummer. Een jaar met 53 weken laat het ritme op de jaarwisseling dus één
--   keer haperen: week 53 en week 1 zijn allebei oneven. Dat is bewust — een
--   doorlopende telling vanaf een peildatum zou niet meer overeenkomen met het
--   weeknummer dat de planner en de apotheek op hun kalender zien, en die
--   afspraak ("wij bezorgen in de even weken") gaat over het weeknummer.
--
-- DE GENERATOR WORDT VERVANGEN, NIET AANGEVULD
--   generate_schedule_shifts() komt uit migratie 009 en wordt hier in zijn
--   geheel opnieuw neergezet met één extra voorwaarde in de dagenlus. De rest
--   van de functie is ongewijzigd overgenomen; 010 en 015 noemen hem alleen in
--   commentaar en hebben hem nooit geherdefinieerd.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- 1. De kolom.
ALTER TABLE public.pharmacy_schedules
  ADD COLUMN IF NOT EXISTS week_parity TEXT NOT NULL DEFAULT 'both'
  CONSTRAINT pharmacy_schedules_parity_chk CHECK (week_parity IN ('even', 'odd', 'both'));

COMMENT ON COLUMN public.pharmacy_schedules.week_parity IS
  'Welke weken deze roosterregel actief is: even ISO-weeknummers, oneven, of alle (both = default). Migratie 045.';

-- ────────────────────────────────────────────────────────────────────────
-- 2. generate_schedule_shifts — ongewijzigd t.o.v. migratie 009, op de
--    pariteitsvoorwaarde in de dagenlus na.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.generate_schedule_shifts(p_horizon_weeks INT DEFAULT 10)
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
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
         AND (r.week_parity = 'both'
              OR (r.week_parity = 'even' AND EXTRACT(WEEK FROM d)::INT % 2 = 0)
              OR (r.week_parity = 'odd'  AND EXTRACT(WEEK FROM d)::INT % 2 = 1))
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

REVOKE ALL     ON FUNCTION public.generate_schedule_shifts(INT) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.generate_schedule_shifts(INT) TO authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────
-- Verificatie — welke regels wijken af van het wekelijkse ritme. Direct na
-- deze migratie is die lijst leeg: alles staat op 'both'.
-- ────────────────────────────────────────────────────────────────────────
-- SELECT s.id, p.name, s.weekday, s.start_time, s.week_parity
--   FROM public.pharmacy_schedules s
--   JOIN public.pharmacies p ON p.id = s.pharmacy_id
--  WHERE s.week_parity <> 'both'
--  ORDER BY p.name, s.weekday;

COMMIT;
