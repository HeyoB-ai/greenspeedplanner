-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — Koeriers-planningsmodule — migratie 001
-- Databasefundament: shifts + koppeltabellen + RLS
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de BESTAANDE Greenspeed-database.
-- Deze module leeft in een aparte repo (greenspeedplanner) maar op dezelfde
-- Supabase-database als de bestaande Greenspeed-bezorgsoftware.
--
-- Afhankelijkheden (moeten al bestaan in deze database):
--   * public.user_profiles(id uuid)      — migratie 001_auth_system.sql
--   * public.pharmacies(id text)         — basis-schema (id is TEXT, geen uuid)
--   * public.institutions(id text)       — migratie 004_institutions.sql
--   * public.is_privileged()             — migratie 007_financials.sql
--
-- Conventie uit het bestaande schema: statusvelden worden als TEXT + CHECK
-- opgeslagen (er zijn GEEN Postgres enum-types in dit schema). Dat volgen we.
-- ════════════════════════════════════════════════════════════════════════


-- ────────────────────────────────────────────────────────────────────────
-- 0. Rolcheck-helper — hergebruik de bestaande is_privileged() uit migratie
--    007. We maken hem ALLEEN aan als hij nog niet bestaat (defensief; bij een
--    correct gemigreerde database is dit een no-op en blijft de bestaande
--    definitie staan). We herdefiniëren de rolcheck bewust NIET.
-- ────────────────────────────────────────────────────────────────────────
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'is_privileged'
  ) THEN
    CREATE FUNCTION public.is_privileged()
    RETURNS boolean AS $fn$
      SELECT EXISTS (
        SELECT 1 FROM public.user_profiles
        WHERE id = auth.uid()
          AND role IN ('superuser', 'supervisor', 'admin')
      );
    $fn$ LANGUAGE sql SECURITY DEFINER STABLE;
  END IF;
END $$;


-- ════════════════════════════════════════════════════════════════════════
-- 1. shifts — één rij per dienst
-- ════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.shifts (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Toegewezen koerier. Nullable: in het latere franchise-biedmodel bestaat
  -- een dienst even zonder koerier (status 'offered'). SET NULL zodat het
  -- verwijderen van een koeriersprofiel geen diensthistorie wist.
  courier_id        UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL,

  -- Vier diensttypes. TEXT + CHECK, consistent met role-kolom in user_profiles.
  shift_type        TEXT NOT NULL
                    CHECK (shift_type IN
                      ('regular', 'institution', 'other_transport', 'urgent')),

  shift_date        DATE NOT NULL,
  start_time        TIME NOT NULL,          -- voorziene starttijd (op shift_date)
  budgeted_end_time TIME,                    -- gebudgetteerde eindtijd (nullable)

  -- Status. Nu functioneel enkel 'planned' (= DEFAULT), maar de CHECK laat nu al
  -- ruimte voor het toekomstige biedmodel (offered → claimed → assigned) zodat
  -- daarvoor géén schema-wijziging nodig is. Het biedmodel zelf zit NIET in
  -- deze migratie.
  status            TEXT NOT NULL DEFAULT 'planned'
                    CHECK (status IN
                      ('planned', 'offered', 'claimed', 'assigned')),

  -- Vrije omschrijving, vooral relevant voor 'urgent' en 'other_transport'.
  description       TEXT,

  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  created_by        UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL
);

-- Indexen ter ondersteuning van de RLS-lookup (courier_id) en planningsquery's.
CREATE INDEX IF NOT EXISTS shifts_courier_id_idx ON public.shifts (courier_id);
CREATE INDEX IF NOT EXISTS shifts_shift_date_idx ON public.shifts (shift_date);


-- ════════════════════════════════════════════════════════════════════════
-- 2. shift_pharmacies — koppeltabel dienst ↔ opdrachtgevende apotheek (m:n)
--    Let op: pharmacy_id is TEXT (pharmacies.id is TEXT, geen uuid).
-- ════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.shift_pharmacies (
  shift_id     UUID NOT NULL REFERENCES public.shifts(id) ON DELETE CASCADE,
  pharmacy_id  TEXT NOT NULL REFERENCES public.pharmacies(id),
  PRIMARY KEY (shift_id, pharmacy_id)
);

CREATE INDEX IF NOT EXISTS shift_pharmacies_pharmacy_id_idx
  ON public.shift_pharmacies (pharmacy_id);


-- ════════════════════════════════════════════════════════════════════════
-- 3. shift_institutions — koppeltabel dienst ↔ bestemming/instelling (m:n)
--    Relevant bij shift_type = 'institution'. institution_id is TEXT.
-- ════════════════════════════════════════════════════════════════════════
CREATE TABLE IF NOT EXISTS public.shift_institutions (
  shift_id        UUID NOT NULL REFERENCES public.shifts(id) ON DELETE CASCADE,
  institution_id  TEXT NOT NULL REFERENCES public.institutions(id),
  PRIMARY KEY (shift_id, institution_id)
);

CREATE INDEX IF NOT EXISTS shift_institutions_institution_id_idx
  ON public.shift_institutions (institution_id);


-- ════════════════════════════════════════════════════════════════════════
-- 4. Row Level Security
-- ════════════════════════════════════════════════════════════════════════
-- Principe "koerier ziet zo min mogelijk", afgedwongen op databaseniveau:
--   * Koerier (rol courier): mag ALLEEN zijn eigen diensten lezen. Geen schrijf.
--   * Planners (superuser/supervisor/admin, via is_privileged()): volledige
--     lees/schrijf-toegang.
--   * Koppeltabellen volgen exact de zichtbaarheid van de shift waar ze aan
--     hangen: een koerier ziet de apotheken/instellingen van zijn EIGEN dienst,
--     niet die van andermans diensten.
--
-- RLS-policies zijn permissive (ge-OR'd). Koeriers krijgen bewust géén
-- INSERT/UPDATE/DELETE-policy → RLS weigert schrijven standaard.
-- ────────────────────────────────────────────────────────────────────────

ALTER TABLE public.shifts             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shift_pharmacies   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shift_institutions ENABLE ROW LEVEL SECURITY;

-- ── shifts ──────────────────────────────────────────────────────────────
-- Lezen: planners alles, koerier enkel eigen diensten.
DROP POLICY IF EXISTS "shifts_select" ON public.shifts;
CREATE POLICY "shifts_select" ON public.shifts
  FOR SELECT
  USING (public.is_privileged() OR courier_id = auth.uid());

-- Aanmaken: alleen planners.
DROP POLICY IF EXISTS "shifts_insert" ON public.shifts;
CREATE POLICY "shifts_insert" ON public.shifts
  FOR INSERT
  WITH CHECK (public.is_privileged());

-- Wijzigen: alleen planners.
DROP POLICY IF EXISTS "shifts_update" ON public.shifts;
CREATE POLICY "shifts_update" ON public.shifts
  FOR UPDATE
  USING (public.is_privileged())
  WITH CHECK (public.is_privileged());

-- Verwijderen: alleen planners.
DROP POLICY IF EXISTS "shifts_delete" ON public.shifts;
CREATE POLICY "shifts_delete" ON public.shifts
  FOR DELETE
  USING (public.is_privileged());

-- ── shift_pharmacies ────────────────────────────────────────────────────
-- Lezen: planners alles; koerier enkel rijen die aan zijn eigen dienst hangen.
DROP POLICY IF EXISTS "shift_pharmacies_select" ON public.shift_pharmacies;
CREATE POLICY "shift_pharmacies_select" ON public.shift_pharmacies
  FOR SELECT
  USING (
    public.is_privileged()
    OR EXISTS (
      SELECT 1 FROM public.shifts s
      WHERE s.id = shift_pharmacies.shift_id
        AND s.courier_id = auth.uid()
    )
  );

-- Schrijven (insert/update/delete): alleen planners.
DROP POLICY IF EXISTS "shift_pharmacies_insert" ON public.shift_pharmacies;
CREATE POLICY "shift_pharmacies_insert" ON public.shift_pharmacies
  FOR INSERT
  WITH CHECK (public.is_privileged());

DROP POLICY IF EXISTS "shift_pharmacies_update" ON public.shift_pharmacies;
CREATE POLICY "shift_pharmacies_update" ON public.shift_pharmacies
  FOR UPDATE
  USING (public.is_privileged())
  WITH CHECK (public.is_privileged());

DROP POLICY IF EXISTS "shift_pharmacies_delete" ON public.shift_pharmacies;
CREATE POLICY "shift_pharmacies_delete" ON public.shift_pharmacies
  FOR DELETE
  USING (public.is_privileged());

-- ── shift_institutions ──────────────────────────────────────────────────
-- Lezen: planners alles; koerier enkel rijen die aan zijn eigen dienst hangen.
DROP POLICY IF EXISTS "shift_institutions_select" ON public.shift_institutions;
CREATE POLICY "shift_institutions_select" ON public.shift_institutions
  FOR SELECT
  USING (
    public.is_privileged()
    OR EXISTS (
      SELECT 1 FROM public.shifts s
      WHERE s.id = shift_institutions.shift_id
        AND s.courier_id = auth.uid()
    )
  );

-- Schrijven (insert/update/delete): alleen planners.
DROP POLICY IF EXISTS "shift_institutions_insert" ON public.shift_institutions;
CREATE POLICY "shift_institutions_insert" ON public.shift_institutions
  FOR INSERT
  WITH CHECK (public.is_privileged());

DROP POLICY IF EXISTS "shift_institutions_update" ON public.shift_institutions;
CREATE POLICY "shift_institutions_update" ON public.shift_institutions
  FOR UPDATE
  USING (public.is_privileged())
  WITH CHECK (public.is_privileged());

DROP POLICY IF EXISTS "shift_institutions_delete" ON public.shift_institutions;
CREATE POLICY "shift_institutions_delete" ON public.shift_institutions
  FOR DELETE
  USING (public.is_privileged());

-- ════════════════════════════════════════════════════════════════════════
-- Einde migratie 001
-- ════════════════════════════════════════════════════════════════════════
