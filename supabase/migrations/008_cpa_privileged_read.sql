-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — planner leest koppelingen — migratie 008
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
--
-- courier_pharmacy_access (CPA) is de echte koerier↔apotheek-koppelbron (gevuld
-- door de code-invoer via link_courier_via_code). Migratie 001 gaf alleen de
-- koerier leesrecht op zijn EIGEN rijen; een planner (is_privileged) kon niets
-- lezen, waardoor de planner terugviel op user_profiles.pharmacy_ids — een
-- drift-gevoelige spiegel (append-only + handmatig bewerkbaar).
--
-- Deze policy laat planners de VOLLEDIGE koppeling lezen, zodat ShiftForm (en
-- straks het roosterscherm) uit één bron putten: CPA. Additief — de bestaande
-- "eigen koppelingen"-policy voor de koerier blijft ongemoeid.
--
-- LET OP — VOLGORDE: draai deze migratie VÓÓR de bijbehorende build live gaat.
-- De nieuwe build leest de koerier-koppelingen uit CPA; zonder deze policy geeft
-- die query 0 rijen en blijft elke koerier-dropdown leeg.
-- ════════════════════════════════════════════════════════════════════════

DROP POLICY IF EXISTS "privileged leest koppelingen" ON public.courier_pharmacy_access;
CREATE POLICY "privileged leest koppelingen" ON public.courier_pharmacy_access
  FOR SELECT
  USING (public.is_privileged());
