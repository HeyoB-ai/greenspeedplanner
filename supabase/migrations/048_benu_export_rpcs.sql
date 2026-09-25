-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — BENU selfbilling: export-RPCs — 048
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor. Vereist migratie 046 en 025.
--
-- Drie leesfuncties voor de weekexports in het BENU-paneel (fase 5):
--   benu_roster_week — roostertijden uit de planning (BENU HQ, tab 1)
--   benu_pda_week    — PDA-minuten zoals de koerier ze opgaf (BENU HQ, tab 2)
--   benu_extra_week  — goedgekeurde extra tijd, per apotheek te factureren
-- Alleen planners en beheerders; de BENU-tabellen blijven zelf dicht
-- (migratie 046).
-- ════════════════════════════════════════════════════════════════════════

-- ────────────────────────────────────────────────────────────────────────
-- benu_roster_week — wat er gepland stond. 'draft' en aangeboden diensten
-- vallen erbuiten: die zijn (nog) niet van een koerier.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.benu_roster_week(p_from DATE, p_to DATE)
RETURNS TABLE (
  shift_date        DATE,
  courier_name      TEXT,
  pharmacy_name     TEXT,
  start_time        TEXT,
  budgeted_end_time TEXT,
  budgeted_minutes  INT
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
    s.shift_date,
    up.name,
    ph.name,
    to_char(s.start_time, 'HH24:MI'),
    to_char(s.budgeted_end_time, 'HH24:MI'),
    sp.budgeted_minutes
  FROM public.shifts s
  JOIN public.shift_pharmacies sp ON sp.shift_id = s.id
  JOIN public.pharmacies ph       ON ph.id = sp.pharmacy_id AND ph.is_benu_selfbilling = true
  JOIN public.user_profiles up    ON up.id = s.courier_id
  WHERE s.shift_date BETWEEN p_from AND p_to
    AND s.status IN ('planned', 'assigned')
  ORDER BY s.shift_date, up.name, ph.name;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.benu_roster_week(DATE, DATE) TO authenticated;


-- ────────────────────────────────────────────────────────────────────────
-- benu_pda_week — alleen regels die de koerier heeft ingediend.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.benu_pda_week(p_from DATE, p_to DATE)
RETURNS TABLE (
  shift_date      DATE,
  courier_name    TEXT,
  pharmacy_name   TEXT,
  planned_minutes INT,
  pda_minutes     INT,
  status          TEXT
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
    s.shift_date,
    up.name,
    pe.pharmacy_name,
    pe.planned_minutes,
    pe.pda_minutes,
    pe.status
  FROM public.benu_shift_entries be
  JOIN public.shifts s                 ON s.id = be.shift_id
  JOIN public.user_profiles up         ON up.id = be.courier_id
  JOIN public.benu_pharmacy_entries pe ON pe.shift_entry_id = be.id
  WHERE s.shift_date BETWEEN p_from AND p_to
    AND pe.status NOT IN ('pending')
  ORDER BY s.shift_date, up.name, pe.pharmacy_name;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.benu_pda_week(DATE, DATE) TO authenticated;


-- ────────────────────────────────────────────────────────────────────────
-- benu_extra_week — extra tijd die de apotheek goedkeurde of liet verlopen.
-- Gesorteerd op apotheek: de export maakt er één tabblad per apotheek van.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.benu_extra_week(p_from DATE, p_to DATE)
RETURNS TABLE (
  shift_date    DATE,
  courier_name  TEXT,
  pharmacy_name TEXT,
  extra_minutes INT,
  extra_reason  TEXT,
  status        TEXT
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
    s.shift_date,
    up.name,
    pe.pharmacy_name,
    GREATEST(0, pe.pda_minutes - pe.planned_minutes),
    pe.extra_reason,
    pe.status
  FROM public.benu_shift_entries be
  JOIN public.shifts s                 ON s.id = be.shift_id
  JOIN public.user_profiles up         ON up.id = be.courier_id
  JOIN public.benu_pharmacy_entries pe ON pe.shift_entry_id = be.id
  WHERE s.shift_date BETWEEN p_from AND p_to
    AND pe.status IN ('approved', 'auto_approved')
    AND pe.pda_minutes IS NOT NULL
    AND pe.planned_minutes IS NOT NULL
    AND pe.pda_minutes > pe.planned_minutes
  ORDER BY pe.pharmacy_name, s.shift_date, up.name;
END;
$fn$;

GRANT EXECUTE ON FUNCTION public.benu_extra_week(DATE, DATE) TO authenticated;
