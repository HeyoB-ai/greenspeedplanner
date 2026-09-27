-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — ziekteverzuim op een dienst — 049
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor.
--
-- Een dienst waarop de koerier ziek is blijft gewoon staan: hij telt mee voor
-- de uitbetaling. Wat er wél uit moet is de post:
--   • geen aankondigingsmail meer (mail_upcoming_subjects)
--   • geen declaratie en geen nabericht (declaration_sweep → shift_followup)
--   • geen BENU-invoerformulier (benu_shifts_to_mail, migratie 046)
-- invoice_lines() joint shift_declarations met een LEFT JOIN, dus een zieke
-- dienst zonder declaratie wordt nog steeds op de geplande tijd gefactureerd.
--
-- De definities hieronder zijn op 27-09-2026 uit de live database gehaald
-- (pg_get_viewdef / pg_get_functiondef); de enige wijziging is NOT s.sick_leave.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien.                       │
-- └────────────────────────────────────────────────────────────────────────┘
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

ALTER TABLE public.shifts
  ADD COLUMN IF NOT EXISTS sick_leave BOOLEAN NOT NULL DEFAULT false;


-- ────────────────────────────────────────────────────────────────────────
-- Aankondigingsmails: geen post over een dienst waarop de koerier ziek is.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.mail_upcoming_subjects AS
WITH upcoming AS (
  SELECT s.id,
         s.courier_id,
         CASE
           WHEN s.schedule_id IS NOT NULL AND NOT ps.courier_id IS DISTINCT FROM s.courier_id THEN 'schedule'::text
           ELSE 'shift'::text
         END AS subject_type,
         CASE
           WHEN s.schedule_id IS NOT NULL AND NOT ps.courier_id IS DISTINCT FROM s.courier_id THEN s.schedule_id
           ELSE s.id
         END AS subject_id
  FROM public.shifts s
  LEFT JOIN public.pharmacy_schedules ps ON ps.id = s.schedule_id
  WHERE s.status = 'planned'::text
    AND s.courier_id IS NOT NULL
    AND NOT s.sick_leave
    AND public.mail_is_upcoming(s.shift_date, s.start_time)
)
SELECT subject_type,
       subject_id,
       courier_id,
       array_agg(DISTINCT public.mail_shift_variant(id, subject_type = 'schedule'::text)) AS variants
FROM upcoming u
GROUP BY subject_type, subject_id, courier_id;


-- ────────────────────────────────────────────────────────────────────────
-- Declaratie + nabericht (shift_followup): niet voor een zieke dienst.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.declaration_sweep(p_limit integer DEFAULT 200)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cfg   public.declaration_settings;
  v_shift RECORD;
  v_dec   UUID;
  v_made  INT := 0;
BEGIN
  SELECT * INTO v_cfg FROM public.declaration_settings WHERE id;

  FOR v_shift IN
    SELECT s.id, s.courier_id, s.shift_date, s.start_time, s.budgeted_end_time,
           s.transport_mode, s.car_is_own
    FROM public.shifts s
    WHERE s.status = 'planned'
      AND s.courier_id IS NOT NULL
      AND NOT s.sick_leave
      AND s.shift_date >= v_cfg.active_from
      AND s.shift_date >= current_date - v_cfg.max_age_days
      AND public.declaration_shift_end(s.shift_date, s.start_time, s.budgeted_end_time) < now()
      AND NOT EXISTS (
        SELECT 1 FROM public.shift_declarations d WHERE d.shift_id = s.id
      )
    ORDER BY s.shift_date, s.start_time
    LIMIT p_limit
  LOOP
    INSERT INTO public.shift_declarations
      (shift_id, courier_id, token_hash, token_expires_at)
    VALUES
      (v_shift.id, v_shift.courier_id,
       public.declaration_hash_token(public.declaration_new_token()),
       (v_shift.shift_date + v_cfg.token_valid_days)::TIMESTAMP AT TIME ZONE 'Europe/Amsterdam')
    ON CONFLICT (shift_id) DO NOTHING
    RETURNING id INTO v_dec;

    -- Niets teruggekregen = een gelijktijdige sweep was ons voor. Doorlopen.
    CONTINUE WHEN v_dec IS NULL;

    PERFORM public.declaration_recompute(v_dec);

    INSERT INTO public.mail_outbox (courier_id, kind, subject_type, subject_id, payload)
    VALUES (
      v_shift.courier_id, 'shift_followup', 'shift', v_shift.id,
      jsonb_build_object(
        'declaration_id',    v_dec,
        'courier_name',      (SELECT name FROM public.user_profiles WHERE id = v_shift.courier_id),
        'shift_date',        v_shift.shift_date,
        'weekday',           EXTRACT(ISODOW FROM v_shift.shift_date),
        'start_time',        to_char(v_shift.start_time, 'HH24:MI'),
        'budgeted_end_time', to_char(v_shift.budgeted_end_time, 'HH24:MI'),
        'transport_mode',    v_shift.transport_mode,
        'own_car',           v_shift.car_is_own IS TRUE,
        'pharmacies',        (SELECT COALESCE(jsonb_agg(p.name ORDER BY p.name), '[]'::jsonb)
                              FROM public.shift_pharmacies sp
                              JOIN public.pharmacies p ON p.id = sp.pharmacy_id
                              WHERE sp.shift_id = v_shift.id)
      ));

    v_made := v_made + 1;
    v_dec  := NULL;
  END LOOP;

  RETURN v_made;
END;
$function$;


-- ────────────────────────────────────────────────────────────────────────
-- BENU-dagmail: geen invoerformulier voor een dienst waarop de koerier ziek is.
-- Rechten blijven staan (alleen service_role); CREATE OR REPLACE laat ze heel.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.benu_shifts_to_mail()
RETURNS TABLE (
  shift_id      UUID,
  shift_date    TEXT,
  courier_id    UUID,
  courier_name  TEXT,
  courier_email TEXT,
  pharmacies    JSONB   -- [{pharmacy_id, pharmacy_name, planned_minutes}]
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT
    s.id,
    to_char(s.shift_date, 'YYYY-MM-DD'),
    s.courier_id,
    up.name,
    (SELECT r.email FROM public.mail_recipient_for(s.courier_id) r),
    jsonb_agg(jsonb_build_object(
      'pharmacy_id',     p.id,
      'pharmacy_name',   p.name,
      'planned_minutes', sp.budgeted_minutes
    ) ORDER BY p.name)
  FROM public.shifts s
  JOIN public.shift_pharmacies sp   ON sp.shift_id = s.id
  JOIN public.pharmacies p          ON p.id = sp.pharmacy_id AND p.is_benu_selfbilling
  LEFT JOIN public.user_profiles up ON up.id = s.courier_id
  WHERE s.shift_date = CURRENT_DATE
    AND s.courier_id IS NOT NULL
    AND s.status IN ('planned', 'assigned')
    AND NOT s.sick_leave
    AND NOT EXISTS (
      SELECT 1 FROM public.benu_shift_entries b WHERE b.shift_id = s.id
    )
  GROUP BY s.id, s.shift_date, s.courier_id, up.name;
$fn$;

COMMIT;
