-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — één bron voor het telefoonnummer — 043
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 029 eerst (die staat sinds 11-09-2026 in de database).
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien, en draai daarna       │
-- │ supabase/tests/043_phone_single_source_test.sql.                       │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAT ER MIS WAS
--   Het telefoonveld in het scherm Medewerkers schreef naar employees.phone. De
--   SMS-keten leest courier_contacts.phone_e164. Niets synchroniseerde die twee.
--
--   Gevolg, en dat is erger dan een leeg veld: een planner vulde een nummer in, zag
--   het terug in beeld, en de koerier kreeg nog steeds geen SMS. Waargenomen bij
--   Mannes van der Burg — nummer ingevuld en opgeslagen, courier_contacts leeg.
--
--   Het waren niet twee verschillende nummers. De bedoeling van employees.phone
--   staat in migratie 029 zelf: "Voor de nadeclaratiemail en de SMS-herinnering."
--   Dat is precies de keten die courier_contacts leest. De auteur van 029 zag dit
--   als de nieuwe plek en heeft de oude nooit omgelegd.
--
-- WAAROM courier_contacts DE BRON IS EN NIET employees.phone
--   1. courier_contacts.phone_e164 is NOT NULL met een CHECK op E.164 (migratie
--      011). employees.phone is TEXT zonder enige beperking. De bron verplaatsen
--      naar de onbeperkte kolom betekent dat '06 12 34 56 78' of een typefout
--      onopgemerkt naar de provider gaat.
--   2. De keten joint toch op user_profiles.id, want diensten verwijzen daarnaar.
--      Wie geen inlogaccount heeft kan per definitie geen dienst en dus geen
--      herinnering krijgen. De vrijheid van 029 — administratie los van accounts —
--      levert voor deze keten niets op.
--   3. Zo hoeven sms_due_shifts() (012) en declaration_reminder_due() (037/041)
--      niet aangeraakt te worden. Die eerste draait in productie.
--
-- WAT DEZE MIGRATIE DOET
--   employee_save() laat phone ongemoeid — niet in de INSERT, en in de UPDATE staat
--   de kolom er niet meer in. Dat laatste is het punt: zou de frontend alleen maar
--   stoppen met het VERSTUREN van phone, dan zou de UPDATE het veld op NULL zetten
--   en de al ingetypte nummers wissen. Die zijn juist het startpunt van de
--   overzetting met de hand.
--
--   De kolom blijft bestaan, met een COMMENT dat hij geen bron is.
--
-- ⚠ WAT DEZE MIGRATIE NIET DOET
--   employee_import() blijft phone schrijven (punt 6 van migratie 029, regel 325 en
--   340). Een CSV met een kolom 'telefoon' vult dus nog steeds employees.phone, en
--   dat nummer bereikt de SMS-keten NIET. Bewust niet aangepast: de import zou dan
--   een ingevuld nummer stilzwijgend weggooien, en dat is erger dan het op de
--   verkeerde plek zetten. Wie de import gebruikt moet de nummers daarna in
--   Beheer → Nummers overnemen. Zie de README voor het voorstel om dat in de
--   voorbeeldweergave van de import te melden.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;


-- ────────────────────────────────────────────────────────────────────────
-- 1. employee_save — phone valt eruit.
--    Body letterlijk uit migratie 029, punt 5, met de kolom phone uit zowel de
--    INSERT als de UPDATE. Al het andere staat er ongewijzigd in, inclusief de
--    is_privileged()-controle en de eis dat voor- en achternaam gevuld zijn.
--
--    De signatuur en het returntype blijven gelijk, dus CREATE OR REPLACE volstaat
--    en de rechten uit 029 blijven staan. De frontend mag phone blijven meesturen;
--    het wordt hier simpelweg genegeerd, en dat maakt de overgang ongevoelig voor
--    de volgorde waarin migratie en frontend worden uitgerold.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.employee_save(p_employee JSONB)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
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
      personnel_number, first_name, last_name, email, employment_type,
      hourly_wage, wage_start_date, home_pharmacy_id, employed_from, employed_until, note)
    VALUES (
      NULLIF(btrim(COALESCE(p_employee ->> 'personnel_number', '')), ''),
      v_first, v_last,
      NULLIF(btrim(COALESCE(p_employee ->> 'email', '')), ''),
      NULLIF(p_employee ->> 'employment_type', ''),
      NULLIF(p_employee ->> 'hourly_wage', '')::NUMERIC,
      NULLIF(p_employee ->> 'wage_start_date', '')::DATE,
      NULLIF(p_employee ->> 'home_pharmacy_id', ''),
      COALESCE(NULLIF(p_employee ->> 'employed_from', '')::DATE, current_date),
      NULLIF(p_employee ->> 'employed_until', '')::DATE,
      NULLIF(btrim(COALESCE(p_employee ->> 'note', '')), ''))
    RETURNING id INTO v_id;
  ELSE
    -- phone staat hier bewust NIET tussen. Een nummer dat er al in staat blijft
    -- staan tot iemand het met de hand overzet naar courier_contacts.
    UPDATE public.employees SET
      personnel_number = NULLIF(btrim(COALESCE(p_employee ->> 'personnel_number', '')), ''),
      first_name       = v_first,
      last_name        = v_last,
      email            = NULLIF(btrim(COALESCE(p_employee ->> 'email', '')), ''),
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
$fn$;


-- ────────────────────────────────────────────────────────────────────────
-- 2. De kolom houdt zijn inhoud, maar niet zijn status.
--    Niet weggooien: er staan nummers in die met de hand overgezet moeten worden,
--    en die zijn het startpunt. Wél vastleggen dat hij geen bron is, want de
--    volgende lezer ziet anders een kolom die 'phone' heet en neemt aan dat het
--    telefoonnummer daar hoort.
-- ────────────────────────────────────────────────────────────────────────
COMMENT ON COLUMN public.employees.phone IS
  'GEEN BRON. Het telefoonnummer voor de SMS-keten staat in '
  'courier_contacts.phone_e164 (migratie 011): daar geldt een CHECK op E.164 en '
  'daar kijken sms_due_shifts() en declaration_reminder_due() naar. Deze kolom '
  'wordt door NIETS gelezen. employee_save() schrijft er sinds migratie 043 niet '
  'meer in; employee_import() nog wel, en een nummer dat daar binnenkomt bereikt '
  'de SMS-keten dus niet — dat moet met de hand naar Beheer > Nummers. Bestaande '
  'waarden zijn bewust bewaard als startpunt voor die overzetting.';


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie
--   1. employee_save raakt phone niet meer aan. Verwacht: geen regel met 'phone'
--      in de definitie, behalve in het commentaar.
--   2. Wie heeft een nummer in employees maar niet in courier_contacts? Dat is
--      exact de lijst die met de hand overgezet moet worden. Leeg = klaar.
--   3. En omgekeerd: wie heeft wél een nummer in courier_contacts? Dat is de
--      enige lijst die voor de SMS-keten telt.
-- ────────────────────────────────────────────────────────────────────────
SELECT count(*) FILTER (WHERE line ILIKE '%phone%' AND line NOT ILIKE '--%') AS regels_met_phone
FROM (SELECT unnest(string_to_array(pg_get_functiondef(p.oid), E'\n')) AS line
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public' AND p.proname = 'employee_save') x;

SELECT e.id, e.first_name, e.last_name, e.phone AS staat_in_employees,
       e.user_profile_id,
       CASE WHEN e.user_profile_id IS NULL THEN 'geen inlogaccount — kan geen SMS krijgen'
            ELSE 'over te zetten naar Beheer > Nummers' END AS actie
FROM public.employees e
LEFT JOIN public.courier_contacts cc ON cc.courier_id = e.user_profile_id
WHERE NULLIF(btrim(COALESCE(e.phone, '')), '') IS NOT NULL
  AND cc.courier_id IS NULL
ORDER BY e.last_name, e.first_name;

SELECT up.name, cc.phone_e164, cc.note, cc.updated_at
FROM public.courier_contacts cc
JOIN public.user_profiles up ON up.id = cc.courier_id
ORDER BY up.name;

COMMIT;   -- vervang door ROLLBACK; voor een dry-run zonder op te slaan
