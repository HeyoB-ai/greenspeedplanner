-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — concept-diensten (status 'draft') — migratie 005
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
--
-- Een planner plant een dienst eerst als CONCEPT ('draft'), overlegt met de
-- koerier en bevestigt daarna (→ 'planned'). Een concept is voor de koerier
-- VOLLEDIG onzichtbaar — dat wordt hier op databaseniveau afgedwongen.
-- ════════════════════════════════════════════════════════════════════════


-- ────────────────────────────────────────────────────────────────────────
-- 1. Statuswaarde 'draft' + nieuwe default + bevestigingsvelden.
--    De status-CHECK uit migratie 001 is een inline (auto-benoemde) constraint;
--    we zoeken hem dynamisch op, droppen hem en zetten een benoemde terug met
--    'draft' erbij. Bestaande rijen worden NIET omgezet (blijven 'planned').
-- ────────────────────────────────────────────────────────────────────────
DO $$
DECLARE c text;
BEGIN
  SELECT conname INTO c
  FROM pg_constraint
  WHERE conrelid = 'public.shifts'::regclass
    AND contype = 'c'
    AND pg_get_constraintdef(oid) ILIKE '%status%'
    AND pg_get_constraintdef(oid) ILIKE '%planned%';
  IF c IS NOT NULL THEN
    EXECUTE format('ALTER TABLE public.shifts DROP CONSTRAINT %I', c);
  END IF;
END $$;

ALTER TABLE public.shifts
  ADD CONSTRAINT shifts_status_check
  CHECK (status IN ('draft', 'planned', 'offered', 'claimed', 'assigned'));

-- Nieuwe diensten zijn voortaan standaard een concept.
ALTER TABLE public.shifts ALTER COLUMN status SET DEFAULT 'draft';

-- Wie heeft wanneer bevestigd.
ALTER TABLE public.shifts
  ADD COLUMN IF NOT EXISTS confirmed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS confirmed_by UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL;


-- ────────────────────────────────────────────────────────────────────────
-- 2. RLS — concept mag NOOIT bij de koerier terechtkomen.
--    We herzien alle drie de courier-lees-paden uit migratie 001 (shifts +
--    beide koppeltabellen) zodat status = 'draft' altijd wordt uitgesloten,
--    ook als courier_id al gevuld is. Planners (is_privileged) zien alles.
--    (De tijdrapport-policies in migratie 006 sluiten 'draft' óók uit, als
--    verdediging in de diepte — een concept levert nooit een tijdrapport op.)
-- ────────────────────────────────────────────────────────────────────────

-- shifts: koerier ziet enkel eigen, niet-concept diensten.
DROP POLICY IF EXISTS "shifts_select" ON public.shifts;
CREATE POLICY "shifts_select" ON public.shifts
  FOR SELECT
  USING (
    public.is_privileged()
    OR (courier_id = auth.uid() AND status <> 'draft')
  );

-- shift_pharmacies: koppelrijen volgen de zichtbaarheid van de dienst.
DROP POLICY IF EXISTS "shift_pharmacies_select" ON public.shift_pharmacies;
CREATE POLICY "shift_pharmacies_select" ON public.shift_pharmacies
  FOR SELECT
  USING (
    public.is_privileged()
    OR EXISTS (
      SELECT 1 FROM public.shifts s
      WHERE s.id = shift_pharmacies.shift_id
        AND s.courier_id = auth.uid()
        AND s.status <> 'draft'
    )
  );

-- shift_institutions: idem.
DROP POLICY IF EXISTS "shift_institutions_select" ON public.shift_institutions;
CREATE POLICY "shift_institutions_select" ON public.shift_institutions
  FOR SELECT
  USING (
    public.is_privileged()
    OR EXISTS (
      SELECT 1 FROM public.shifts s
      WHERE s.id = shift_institutions.shift_id
        AND s.courier_id = auth.uid()
        AND s.status <> 'draft'
    )
  );
