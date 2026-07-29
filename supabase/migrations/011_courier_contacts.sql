-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — telefoonnummers van koeriers — migratie 011
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
--
-- Waarom een APARTE tabel en geen kolom op user_profiles:
--   * user_profiles is de productietabel van de bezorg-app. Een gebruiker mag
--     daar zijn eigen rij lezen (policy "privileged profielen lezen", migratie
--     007 van de bezorg-app) en authService.login() haalt hem op met select('*'),
--     waardoor het nummer in de bezorg-app-client zou belanden.
--   * Hier gelden alleen is_privileged()-policies: géén koerier kan een nummer
--     lezen of schrijven — ook zijn eigen niet, laat staan dat van een collega.
--   * Doelbinding (AVG): het nummer bestaat om één SMS te sturen. Aparte tabel
--     = duidelijk doel, één DELETE om het te wissen, en later terug te draaien
--     zonder de productietabel van de bezorg-app aan te raken.
--
-- Afhankelijkheden (bestaan al): public.user_profiles(id), public.is_privileged().
-- ════════════════════════════════════════════════════════════════════════


-- ────────────────────────────────────────────────────────────────────────
-- 1. courier_contacts — één nummer per koerier.
--    Opslag in E.164 (+316…): dat is wat elke SMS-provider verwacht, en het
--    voorkomt dat '06 12 34 56 78' en '+31612345678' als twee vormen naast
--    elkaar gaan leven. De app normaliseert vóór het opslaan; de CHECK hier is
--    het laatste vangnet, niet de eerste controle.
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.courier_contacts (
  courier_id  UUID PRIMARY KEY REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  phone_e164  TEXT NOT NULL CHECK (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  note        TEXT,                       -- bv. 'werktelefoon' / 'prive'
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by  UUID REFERENCES public.user_profiles(id) ON DELETE SET NULL
);

-- Verdwijnt de koerier, dan verdwijnt het nummer (ON DELETE CASCADE hierboven).
-- Bewust géén uniciteit op phone_e164: twee koeriers die hetzelfde toestel
-- delen is ongebruikelijk maar geen datafout, en een unique-violation zou het
-- beheerscherm blokkeren zonder dat de planner begrijpt waarom.


-- ────────────────────────────────────────────────────────────────────────
-- 2. RLS — planner-only, in beide richtingen.
--    Koeriers hebben geen enkele policy op deze tabel → RLS weigert alles.
--    De nachtelijke SMS-job leest met de service-role key en omzeilt RLS.
-- ────────────────────────────────────────────────────────────────────────
ALTER TABLE public.courier_contacts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "contacts_privileged" ON public.courier_contacts;
CREATE POLICY "contacts_privileged" ON public.courier_contacts
  FOR ALL USING (public.is_privileged()) WITH CHECK (public.is_privileged());


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie — verwacht: één tabel, RLS aan, precies één policy (ALL).
-- ────────────────────────────────────────────────────────────────────────
-- SELECT relname, relrowsecurity FROM pg_class WHERE relname = 'courier_contacts';
-- SELECT policyname, cmd, qual, with_check FROM pg_policies
-- WHERE schemaname = 'public' AND tablename = 'courier_contacts';
