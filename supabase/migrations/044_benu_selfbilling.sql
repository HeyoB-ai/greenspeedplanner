-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — BENU selfbilling-apotheken markeren — 044
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien.                       │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAAROM
--   Bij een BENU selfbilling-apotheek stelt BENU HQ de factuur zelf op; wij
--   sturen er dus géén factuur heen. Dat is nu kennis die in iemands hoofd zit
--   en per apotheek verschilt. Fase 1 zet die kennis in de database en maakt hem
--   zichtbaar in het apotheekbeheer; wat de facturatie er vervolgens mee doet,
--   volgt in een latere fase. Zolang alleen deze vlag bestaat verandert er niets
--   aan bestaande stromen — hij is enkel administratief.
--
-- FALSE ALS STANDAARD
--   De gewone stroom is de grootste groep, en een apotheek die per ongeluk als
--   selfbilling zou gelden krijgt stil geen factuur. Een gemiste vlag valt op
--   (BENU klaagt), een onterechte vlag niet. Vandaar NOT NULL DEFAULT false.
--
-- SCHRIJVEN GAAT VIA EEN FUNCTIE
--   pharmacies is een gedeelde productietabel van de bezorg-app. In plaats van
--   daar schrijfrechten op uit te delen — die gelden dan meteen voor élke kolom —
--   loopt het bijwerken via set_pharmacy_benu_selfbilling(), die zelf op
--   is_privileged() controleert. Zelfde keuze als bij set_pharmacy_city
--   (migratie 024) en de standplaats (migratie 018).
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- 1. De vlag zelf.
ALTER TABLE public.pharmacies
  ADD COLUMN IF NOT EXISTS is_benu_selfbilling BOOLEAN NOT NULL DEFAULT false;

COMMENT ON COLUMN public.pharmacies.is_benu_selfbilling IS
  'true = BENU selfbilling-apotheek: BENU HQ stelt de factuur zelf op, wij sturen '
  'er geen. Vanaf migratie 044 te zetten via het apotheekbeheer in de planner. '
  'false (de standaard) = gewone facturatiestroom.';

-- 2. Lezen. Staan er op deze gedeelde tabel kolomrechten in plaats van één
--    tabelrecht, dan valt een nieuwe kolom daarbuiten en ziet de planner hem
--    niet. Bestaat het tabelrecht al, dan is dit een no-op.
GRANT SELECT (is_benu_selfbilling) ON public.pharmacies TO authenticated;

-- ────────────────────────────────────────────────────────────────────────
-- 3. set_pharmacy_benu_selfbilling — de enige schrijfweg.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_pharmacy_benu_selfbilling(
  p_pharmacy_id TEXT,
  p_value       BOOLEAN
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'Alleen planners mogen de BENU selfbilling-vlag zetten.';
  END IF;

  UPDATE public.pharmacies
     SET is_benu_selfbilling = COALESCE(p_value, false)
   WHERE id = p_pharmacy_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Geen apotheek met id %.', p_pharmacy_id;
  END IF;
END;
$$;

REVOKE ALL     ON FUNCTION public.set_pharmacy_benu_selfbilling(TEXT, BOOLEAN) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.set_pharmacy_benu_selfbilling(TEXT, BOOLEAN) TO authenticated, service_role;

-- ────────────────────────────────────────────────────────────────────────
-- Verificatie — welke apotheken staan na deze migratie als selfbilling
-- gemarkeerd. Direct na het draaien is die lijst leeg: de vlag wordt in het
-- apotheekbeheer gezet, niet hier.
-- ────────────────────────────────────────────────────────────────────────
-- SELECT id, name, is_benu_selfbilling
--   FROM public.pharmacies
--  ORDER BY is_benu_selfbilling DESC, name;

COMMIT;
