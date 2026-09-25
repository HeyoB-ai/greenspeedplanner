-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — BENU selfbilling: planneroverzicht — 047
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor.
-- Draai migratie 046 eerst (die maakte benu_shift_entries en
-- benu_pharmacy_entries).
--
-- Alleen lezen: de planner ziet per dienst-apotheek wat de koerier opgaf en
-- wat de apotheek ervan vond. De tabellen zelf blijven dicht voor
-- authenticated (migratie 046); deze functie is de enige ingang, en die
-- laat alleen planners en beheerders door.
--
-- extra_minutes blijft NULL als gepland of PDA ontbreekt. Een 0 zou hier
-- "geen extra tijd" beweren terwijl er gewoon niets bekend is.
-- ════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION public.benu_entries_overview(
  p_from DATE DEFAULT CURRENT_DATE - 30,
  p_to   DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
  shift_entry_id   UUID,
  shift_date       DATE,
  courier_name     TEXT,
  submitted_at     TIMESTAMPTZ,
  courier_note     TEXT,
  pharmacy_id      TEXT,
  pharmacy_name    TEXT,
  planned_minutes  INT,
  pda_minutes      INT,
  extra_minutes    INT,
  status           TEXT,
  responded_at     TIMESTAMPTZ,
  dispute_deadline TIMESTAMPTZ,
  pharmacy_note    TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  IF NOT is_privileged() THEN
    RAISE EXCEPTION 'Geen toegang' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    be.id,
    s.shift_date,
    up.name,
    be.submitted_at,
    be.courier_note,
    pe.pharmacy_id,
    pe.pharmacy_name,
    pe.planned_minutes,
    pe.pda_minutes,
    CASE WHEN pe.pda_minutes IS NOT NULL AND pe.planned_minutes IS NOT NULL
         THEN GREATEST(0, pe.pda_minutes - pe.planned_minutes)
    END,
    pe.status,
    pe.responded_at,
    pe.dispute_deadline,
    pe.pharmacy_note
  FROM public.benu_shift_entries be
  JOIN public.shifts s                 ON s.id = be.shift_id
  JOIN public.user_profiles up         ON up.id = be.courier_id
  JOIN public.benu_pharmacy_entries pe ON pe.shift_entry_id = be.id
  WHERE s.shift_date BETWEEN p_from AND p_to
  ORDER BY s.shift_date DESC, up.name, pe.pharmacy_name;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.benu_entries_overview(DATE, DATE) TO authenticated;
