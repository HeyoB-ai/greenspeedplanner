-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — personeelsadministratie los van toegang — 029
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien, en draai daarna       │
-- │ supabase/tests/029_employees_test.sql.                                 │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- Het volledige ontwerp staat in docs/FASE8_PERSONEEL_ONTWERP.md.
--
-- WAAROM DEZE TABEL BESTAAT
--   user_profiles.id heeft een foreign key naar auth.users(id) met ON DELETE
--   CASCADE. Daardoor kan er geen medewerker bestaan zonder inlogaccount, en
--   sleept een verwijderd auth-account het profiel mee — met de urenhistorie
--   eraan. Loonadministratie moet zeven jaar bewaard blijven, dus dat mag niet.
--
--   Personeelsadministratie en toegangsbeheer zijn twee dingen. employees is de
--   eerste; user_profiles blijft de tweede en wordt hier NIET verbouwd.
--
-- ┌─ DE REGEL DIE ERTOE DOET ──────────────────────────────────────────────┐
-- │ employees.user_profile_id staat op ON DELETE SET NULL. Verdwijnt het   │
-- │ auth-account, dan verliest de medewerker zijn inlog — niet zijn         │
-- │ historie. Dat is de hele reden dat deze tabel bestaat.                  │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAT DEZE MIGRATIE NIET DOET
--   * shifts blijft ongemoeid. Of een dienst voortaan naar een employee wijst is
--     een besluit met gevolgen voor AIrouteplanner en de bezorg-app; drie
--     varianten met hun afweging staan in punt 4 van het ontwerpdocument en
--     wachten op een keuze.
--   * De regiolaag komt er niet in. Conclusie (punt 3 van het ontwerp): een
--     eigen laag, niet groups — maar dat is een aparte migratie.
--   * Geen opschoonroutine voor oud-medewerkers. Zie punt 7 van het ontwerp.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────
-- 1. employees
--    Velden volgen het tabblad 'Pers. data' uit de L1nda-export:
--    personeelsnummer, achternaam, voornaam, uren, dagen, filiaal.
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.employees (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Zeven van de 69 hebben geen personeelsnummer. Een gewone UNIQUE laat
  -- meerdere NULL's toe, dus "geen nummer" botst nergens mee en hoeft niet
  -- geweigerd te worden.
  personnel_number  TEXT UNIQUE,

  first_name        TEXT NOT NULL,
  last_name         TEXT NOT NULL,

  -- Voor de nadeclaratiemail en de SMS-herinnering. Niet voor inloggen: dat
  -- loopt via auth.users, en die twee moeten uit elkaar blijven.
  email             TEXT CHECK (email IS NULL OR position('@' in email) > 1),
  phone             TEXT,

  employment_type   TEXT CHECK (employment_type IN ('loondienst', 'zzp')),
  hourly_wage       NUMERIC(8,2) CHECK (hourly_wage IS NULL OR hourly_wage >= 0),
  wage_start_date   DATE,

  -- Standplaats, voor de reiskostenberekening (fase 6). Dezelfde betekenis als
  -- user_profiles.home_pharmacy_id uit migratie 018.
  home_pharmacy_id  TEXT REFERENCES public.pharmacies(id),

  -- In dienst is een datumbereik, geen vinkje. employed_until in het verleden =
  -- uit dienst, maar de rij blijft staan: een urenexport over maart bevat hem
  -- gewoon, want toen werkte hij nog.
  employed_from     DATE NOT NULL DEFAULT current_date,
  employed_until    DATE,

  -- De brug naar toegangsbeheer. Leeg voor wie (nog) niet inlogt.
  -- ON DELETE SET NULL: zie het kader bovenaan.
  user_profile_id   UUID UNIQUE REFERENCES public.user_profiles(id) ON DELETE SET NULL,

  note              TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.employees
  DROP CONSTRAINT IF EXISTS employees_period_chk;
ALTER TABLE public.employees
  ADD CONSTRAINT employees_period_chk
  CHECK (employed_until IS NULL OR employed_until >= employed_from);

CREATE INDEX IF NOT EXISTS employees_name_idx ON public.employees (last_name, first_name);
CREATE INDEX IF NOT EXISTS employees_active_idx ON public.employees (employed_from, employed_until);

COMMENT ON TABLE public.employees IS
  'Personeelsadministratie (migratie 029), onafhankelijk van auth.users. '
  'user_profile_id koppelt aan toegangsbeheer voor wie inlogt en staat op '
  'ON DELETE SET NULL: een verwijderd account mag geen historie meenemen.';


-- ────────────────────────────────────────────────────────────────────────
-- 2. In dienst op een datum — op één plek.
--    Zou elk scherm dit zelf doen, dan staat er vroeg of laat ergens
--    "employed_until IS NULL" en werkt een uitdiensttreding niet door.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.employee_active_on(p_employee_id UUID, p_date DATE)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT e.employed_from <= p_date
     AND (e.employed_until IS NULL OR e.employed_until >= p_date)
  FROM public.employees e
  WHERE e.id = p_employee_id;
$$;

-- De view voor het gewone geval: wie is er vandaag in dienst. Dezelfde
-- uitdrukking, zodat er één definitie is en niet twee die uiteen kunnen lopen.
--
-- security_invoker = true is hier geen detail. Zonder die instelling draait een
-- view met de rechten van zijn EIGENAAR, en die is postgres — dan omzeilt de
-- view de RLS van employees en leest elke ingelogde gebruiker de uurlonen. Met
-- security_invoker geldt de policy van punt 4 gewoon.
CREATE OR REPLACE VIEW public.employees_active
  WITH (security_invoker = true) AS
  SELECT e.*,
         (e.employed_from <= current_date
          AND (e.employed_until IS NULL OR e.employed_until >= current_date)) AS is_active
  FROM public.employees e;


-- ────────────────────────────────────────────────────────────────────────
-- 3. updated_at bijhouden. Bij 69 rijen die met de hand en per import gewijzigd
--    worden is "wanneer is dit voor het laatst aangeraakt" het eerste wat je
--    wilt weten als er iets niet klopt.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.employees_touch()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS employees_touch_trg ON public.employees;
CREATE TRIGGER employees_touch_trg
  BEFORE UPDATE ON public.employees
  FOR EACH ROW EXECUTE FUNCTION public.employees_touch();


-- ────────────────────────────────────────────────────────────────────────
-- 4. RLS. Salaris en telefoonnummers: alleen planners, en schrijven via de
--    functies hieronder. Zelfde opzet als de tabellen uit fase 6 en 7.
-- ────────────────────────────────────────────────────────────────────────
ALTER TABLE public.employees ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "employees_privileged_read" ON public.employees;
CREATE POLICY "employees_privileged_read" ON public.employees
  FOR SELECT USING (public.is_privileged());

GRANT SELECT ON public.employees        TO authenticated;
GRANT SELECT ON public.employees_active TO authenticated;


-- ────────────────────────────────────────────────────────────────────────
-- 5. Bewerken — via functies, met een is_privileged()-controle.
--    Verwijderen zit er niet bij: uit dienst is een datum. Dat is geen
--    vergetelheid maar het uitgangspunt van deze tabel.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.employee_save(p_employee JSONB)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_id    UUID := NULLIF(p_employee ->> 'id', '')::UUID;
  v_first TEXT := btrim(COALESCE(p_employee ->> 'first_name', ''));
  v_last  TEXT := btrim(COALESCE(p_employee ->> 'last_name', ''));
BEGIN
  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'Alleen planners mogen medewerkers beheren.';
  END IF;
  IF v_first = '' OR v_last = '' THEN
    RAISE EXCEPTION 'Voornaam en achternaam zijn verplicht.';
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO public.employees (
      personnel_number, first_name, last_name, email, phone, employment_type,
      hourly_wage, wage_start_date, home_pharmacy_id, employed_from, employed_until, note)
    VALUES (
      NULLIF(btrim(COALESCE(p_employee ->> 'personnel_number', '')), ''),
      v_first, v_last,
      NULLIF(btrim(COALESCE(p_employee ->> 'email', '')), ''),
      NULLIF(btrim(COALESCE(p_employee ->> 'phone', '')), ''),
      NULLIF(p_employee ->> 'employment_type', ''),
      NULLIF(p_employee ->> 'hourly_wage', '')::NUMERIC,
      NULLIF(p_employee ->> 'wage_start_date', '')::DATE,
      NULLIF(p_employee ->> 'home_pharmacy_id', ''),
      COALESCE(NULLIF(p_employee ->> 'employed_from', '')::DATE, current_date),
      NULLIF(p_employee ->> 'employed_until', '')::DATE,
      NULLIF(btrim(COALESCE(p_employee ->> 'note', '')), ''))
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.employees SET
      personnel_number = NULLIF(btrim(COALESCE(p_employee ->> 'personnel_number', '')), ''),
      first_name       = v_first,
      last_name        = v_last,
      email            = NULLIF(btrim(COALESCE(p_employee ->> 'email', '')), ''),
      phone            = NULLIF(btrim(COALESCE(p_employee ->> 'phone', '')), ''),
      employment_type  = NULLIF(p_employee ->> 'employment_type', ''),
      hourly_wage      = NULLIF(p_employee ->> 'hourly_wage', '')::NUMERIC,
      wage_start_date  = NULLIF(p_employee ->> 'wage_start_date', '')::DATE,
      home_pharmacy_id = NULLIF(p_employee ->> 'home_pharmacy_id', ''),
      employed_from    = COALESCE(NULLIF(p_employee ->> 'employed_from', '')::DATE, employed_from),
      employed_until   = NULLIF(p_employee ->> 'employed_until', '')::DATE,
      note             = NULLIF(btrim(COALESCE(p_employee ->> 'note', '')), '')
    WHERE id = v_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Geen medewerker met id %.', v_id;
    END IF;
  END IF;

  RETURN v_id;
END;
$$;

-- Een medewerker aan een bestaand inlogaccount hangen, of die koppeling weer
-- losmaken. Apart van employee_save(): dit raakt toegangsbeheer en hoort een
-- bewuste handeling te zijn, geen veld dat meelift in een formulier.
CREATE OR REPLACE FUNCTION public.employee_link_profile(
  p_employee_id UUID, p_user_profile_id UUID
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'Alleen planners mogen een inlogaccount koppelen.';
  END IF;

  IF p_user_profile_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM public.user_profiles WHERE id = p_user_profile_id) THEN
    RAISE EXCEPTION 'Geen profiel met id %.', p_user_profile_id;
  END IF;

  UPDATE public.employees SET user_profile_id = p_user_profile_id WHERE id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Geen medewerker met id %.', p_employee_id;
  END IF;
END;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 6. Import — een lijst rijen in één keer.
--    Koppelt op personeelsnummer; ontbreekt dat, dan op voor- en achternaam
--    (hoofdletterongevoelig). Bestaat de medewerker al, dan wordt hij
--    BIJGEWERKT en niet gedupliceerd — de lijst is dus opnieuw te draaien als er
--    een kolom verkeerd stond, en dat is precies wat je wilt bij 69 rijen uit
--    een export die je nog nooit hebt zien landen.
--
--    Leeggelaten velden overschrijven niets: wie in het scherm een telefoonnummer
--    heeft toegevoegd raakt dat niet kwijt door een herimport van een lijst
--    waarin die kolom niet voorkomt.
--
--    Geeft per rij terug wat er gebeurd is, zodat het scherm een verslag kan
--    tonen in plaats van "69 verwerkt".
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.employee_import(p_rows JSONB)
RETURNS TABLE (
  row_number       INT,
  personnel_number TEXT,
  full_name        TEXT,
  action           TEXT,     -- 'nieuw' | 'bijgewerkt' | 'overgeslagen'
  note             TEXT
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_row   JSONB;
  v_i     INT := 0;
  v_pn    TEXT;
  v_first TEXT;
  v_last  TEXT;
  v_id    UUID;
  v_notes TEXT[];
BEGIN
  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'Alleen planners mogen medewerkers importeren.';
  END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(COALESCE(p_rows, '[]'::jsonb))
  LOOP
    v_i     := v_i + 1;
    v_notes := ARRAY[]::TEXT[];
    v_pn    := NULLIF(btrim(COALESCE(v_row ->> 'personnel_number', '')), '');
    v_first := btrim(COALESCE(v_row ->> 'first_name', ''));
    v_last  := btrim(COALESCE(v_row ->> 'last_name', ''));

    row_number       := v_i;
    personnel_number := v_pn;
    full_name        := btrim(v_first || ' ' || v_last);

    IF v_first = '' OR v_last = '' THEN
      action := 'overgeslagen';
      note   := 'voornaam of achternaam ontbreekt';
      RETURN NEXT;
      CONTINUE;
    END IF;

    -- Zoeken: eerst op nummer, anders op naam.
    IF v_pn IS NOT NULL THEN
      SELECT e.id INTO v_id FROM public.employees e WHERE e.personnel_number = v_pn;
    ELSE
      v_notes := v_notes || 'geen personeelsnummer'::TEXT;
      SELECT e.id INTO v_id FROM public.employees e
       WHERE e.personnel_number IS NULL
         AND lower(e.first_name) = lower(v_first)
         AND lower(e.last_name)  = lower(v_last);
    END IF;

    IF v_id IS NULL THEN
      INSERT INTO public.employees (
        personnel_number, first_name, last_name, email, phone, employment_type,
        hourly_wage, wage_start_date, home_pharmacy_id, employed_from, employed_until)
      VALUES (
        v_pn, v_first, v_last,
        NULLIF(btrim(COALESCE(v_row ->> 'email', '')), ''),
        NULLIF(btrim(COALESCE(v_row ->> 'phone', '')), ''),
        NULLIF(v_row ->> 'employment_type', ''),
        NULLIF(v_row ->> 'hourly_wage', '')::NUMERIC,
        NULLIF(v_row ->> 'wage_start_date', '')::DATE,
        NULLIF(v_row ->> 'home_pharmacy_id', ''),
        COALESCE(NULLIF(v_row ->> 'employed_from', '')::DATE, current_date),
        NULLIF(v_row ->> 'employed_until', '')::DATE)
      RETURNING id INTO v_id;
      action := 'nieuw';
    ELSE
      -- COALESCE(nieuw, oud): een lege kolom in de lijst laat staan wat er stond.
      UPDATE public.employees e SET
        first_name       = v_first,
        last_name        = v_last,
        email            = COALESCE(NULLIF(btrim(COALESCE(v_row ->> 'email', '')), ''), e.email),
        phone            = COALESCE(NULLIF(btrim(COALESCE(v_row ->> 'phone', '')), ''), e.phone),
        employment_type  = COALESCE(NULLIF(v_row ->> 'employment_type', ''), e.employment_type),
        hourly_wage      = COALESCE(NULLIF(v_row ->> 'hourly_wage', '')::NUMERIC, e.hourly_wage),
        wage_start_date  = COALESCE(NULLIF(v_row ->> 'wage_start_date', '')::DATE, e.wage_start_date),
        home_pharmacy_id = COALESCE(NULLIF(v_row ->> 'home_pharmacy_id', ''), e.home_pharmacy_id),
        employed_from    = COALESCE(NULLIF(v_row ->> 'employed_from', '')::DATE, e.employed_from),
        employed_until   = COALESCE(NULLIF(v_row ->> 'employed_until', '')::DATE, e.employed_until)
      WHERE e.id = v_id;
      action := 'bijgewerkt';
    END IF;

    note := CASE WHEN array_length(v_notes, 1) IS NOT NULL
                 THEN array_to_string(v_notes, '; ') END;
    RETURN NEXT;
    v_id := NULL;
  END LOOP;
END;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 7. Rechten.
-- ────────────────────────────────────────────────────────────────────────
REVOKE ALL     ON FUNCTION public.employee_active_on(UUID, DATE)        FROM PUBLIC, anon;
REVOKE ALL     ON FUNCTION public.employee_save(JSONB)                  FROM PUBLIC, anon;
REVOKE ALL     ON FUNCTION public.employee_link_profile(UUID, UUID)     FROM PUBLIC, anon;
REVOKE ALL     ON FUNCTION public.employee_import(JSONB)                FROM PUBLIC, anon;

GRANT  EXECUTE ON FUNCTION public.employee_active_on(UUID, DATE)        TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.employee_save(JSONB)                  TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.employee_link_profile(UUID, UUID)     TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.employee_import(JSONB)                TO authenticated, service_role;


-- ────────────────────────────────────────────────────────────────────────
-- 8. De bestaande koeriers overnemen.
--    Voor elke koerier in user_profiles een employees-rij met user_profile_id
--    ingevuld. Niets weggooien, niets aan user_profiles wijzigen.
--
--    employment_type, hourly_wage en wage_start_date komen via to_jsonb() uit
--    het profiel. Dat is bewust indirect: dit zijn kolommen van de bezorg-app en
--    hun exacte schrijfwijze staat nergens in deze repo vast. Bestaat er een
--    niet, dan levert dat hier NULL op in plaats van een migratie die omvalt.
--
--    De naam wordt op de EERSTE spatie gesplitst: "Jan de Vries" wordt
--    Jan + de Vries. Dat klopt voor tussenvoegsels en niet voor dubbele
--    voornamen; het beheerscherm laat het corrigeren.
--
--    employed_from wordt de eerste dienst die van deze koerier bekend is, en
--    anders vandaag. Een verzonnen datum zou in een urenexport terechtkomen.
-- ────────────────────────────────────────────────────────────────────────
INSERT INTO public.employees (
  first_name, last_name, employment_type, hourly_wage, wage_start_date,
  home_pharmacy_id, employed_from, user_profile_id, note)
SELECT
  COALESCE(NULLIF(split_part(btrim(up.name), ' ', 1), ''), btrim(up.name)),
  COALESCE(NULLIF(btrim(substr(btrim(up.name), length(split_part(btrim(up.name), ' ', 1)) + 1)), ''), '-'),
  CASE WHEN lower(btrim(to_jsonb(up) ->> 'employmentType')) IN ('loondienst', 'zzp')
       THEN lower(btrim(to_jsonb(up) ->> 'employmentType')) END,
  NULLIF(to_jsonb(up) ->> 'hourlyWage', '')::NUMERIC,
  NULLIF(to_jsonb(up) ->> 'wageStartDate', '')::DATE,
  up.home_pharmacy_id,
  COALESCE((SELECT min(s.shift_date) FROM public.shifts s WHERE s.courier_id = up.id), current_date),
  up.id,
  'overgenomen uit user_profiles bij migratie 029'
FROM public.user_profiles up
WHERE up.role = 'courier'
  AND NOT EXISTS (SELECT 1 FROM public.employees e WHERE e.user_profile_id = up.id);


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie
--   1. Hoeveel medewerkers, en hoeveel daarvan hebben een inlogaccount.
--   2. De overgenomen koeriers, om de naamsplitsing na te lopen — dat is het
--      enige wat een mens hier moet controleren.
-- ────────────────────────────────────────────────────────────────────────
SELECT count(*)                             AS medewerkers,
       count(user_profile_id)               AS met_inlogaccount,
       count(*) FILTER (WHERE personnel_number IS NULL) AS zonder_personeelsnummer,
       count(*) FILTER (WHERE employed_until IS NOT NULL
                          AND employed_until < current_date) AS uit_dienst
FROM public.employees;

SELECT e.personnel_number, e.first_name, e.last_name, up.name AS profielnaam,
       e.employment_type, e.employed_from, e.home_pharmacy_id
FROM public.employees e
LEFT JOIN public.user_profiles up ON up.id = e.user_profile_id
WHERE e.user_profile_id IS NOT NULL
ORDER BY e.last_name, e.first_name;

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
