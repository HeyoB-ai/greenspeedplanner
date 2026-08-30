-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — plaatsnaam bewerkbaar maken — migratie 024
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien, en draai daarna       │
-- │ supabase/tests/024_pharmacy_city_test.sql.                             │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- ┌─ EERST DIT LEZEN ──────────────────────────────────────────────────────┐
-- │ public.pharmacies HEEFT AL EEN city-KOLOM. De tabel is van de bezorg-  │
-- │ app en kent street, houseNumber, postalCode, city én een vrije         │
-- │ adresregel `address`; scripts/backfill-pharmacy-coords.mjs (fase 1)    │
-- │ leest ze alle vijf. Het beeld dat de plaats "in dezelfde kolom als     │
-- │ straat en huisnummer" zit klopt alleen voor de apotheken waarbij       │
-- │ uitsluitend `address` gevuld is — daar staat alles in één regel.       │
-- │                                                                        │
-- │ Deze migratie voegt dus vrijwel zeker niets toe aan het schema. Wat er │
-- │ wél ontbrak is de mogelijkheid om het veld te vullen: het is nooit     │
-- │ bewerkbaar geweest vanuit de planner.                                  │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAT DEZE MIGRATIE DOET
--   1. De kolom aanmaken als hij tóch niet blijkt te bestaan (vangnet, no-op op
--      een database waar hij al staat — bestaande waarden blijven ongemoeid).
--   2. Leesrecht op die kolom voor de planner.
--   3. set_pharmacy_city(): de schrijfweg.
--
-- WAAROM ER NIET GEPARSEERD WORDT
--   Voor de apotheken zonder losse velden zou je de plaats uit `address` kunnen
--   vissen. De schrijfwijzen lopen uiteen (met en zonder postcode, met en zonder
--   komma), dus een parser doet het meestal goed en soms stil fout — en dan staan
--   "Hilversum" en "1213 BE Hilversum" als twee plaatsen in het overzicht. Een
--   foute groepering is erger dan geen groepering, want die eerste ziet niemand.
--   Handmatig vullen dus; vijftien apotheken zijn in tien minuten gedaan.
--
-- SCHRIJVEN GAAT VIA EEN FUNCTIE
--   pharmacies is een gedeelde productietabel. In plaats van daar schrijfrechten
--   op uit te delen — die gelden dan meteen voor élke kolom — loopt het bijwerken
--   via set_pharmacy_city(), die zelf op is_privileged() controleert. Zelfde
--   keuze als bij de standplaats in migratie 018.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- 1. Vangnet. Bestaat de kolom al (verwacht), dan gebeurt hier niets en blijven
--    de ingevulde plaatsen staan.
ALTER TABLE public.pharmacies
  ADD COLUMN IF NOT EXISTS city TEXT;

COMMENT ON COLUMN public.pharmacies.city IS
  'Plaatsnaam, los van de vrije adresregel. Vanaf migratie 024 te vullen via het '
  'apotheekbeheer in de planner; bewust NIET afgeleid uit address, want de '
  'schrijfwijzen lopen uiteen. NULL = onbekend; die apotheken groeperen in het '
  'weekoverzicht onder "Overig".';

-- 2. Lezen. Staan er op deze gedeelde tabel kolomrechten in plaats van één
--    tabelrecht, dan valt een kolom daarbuiten en ziet de planner hem niet. Dit
--    recht expliciet toekennen is in beide gevallen goed: bestaat het tabelrecht
--    al, dan is dit een no-op.
GRANT SELECT (city) ON public.pharmacies TO authenticated;

-- ────────────────────────────────────────────────────────────────────────
-- 3. set_pharmacy_city — de enige schrijfweg.
--    Leeg opslaan wist het veld: dan staat de apotheek weer onder "Overig", en
--    dat is een geldige uitkomst (bijvoorbeeld na een verkeerd getypte plaats).
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_pharmacy_city(p_pharmacy_id TEXT, p_city TEXT)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'Alleen planners mogen de plaats van een apotheek zetten.';
  END IF;

  UPDATE public.pharmacies
     SET city = NULLIF(btrim(COALESCE(p_city, '')), '')
   WHERE id = p_pharmacy_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Geen apotheek met id %.', p_pharmacy_id;
  END IF;
END;
$$;

REVOKE ALL     ON FUNCTION public.set_pharmacy_city(TEXT, TEXT) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.set_pharmacy_city(TEXT, TEXT) TO authenticated, service_role;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie — hoeveel apotheken hebben al een plaats, en welke niet. Die
-- tweede lijst is meteen de werklijst voor het apotheekbeheer; `address` staat
-- erbij zodat je hem kunt overtypen zonder een tweede scherm.
-- ────────────────────────────────────────────────────────────────────────
SELECT count(*)                  AS apotheken,
       count(city)               AS met_plaats,
       count(*) - count(city)    AS nog_te_vullen
FROM public.pharmacies;

SELECT id, name, city, address
FROM public.pharmacies
WHERE city IS NULL
ORDER BY name;

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
