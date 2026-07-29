-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — vangnet voor verwijderde roosterconcepten — migratie 010
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor. Draai 009 eerst.
-- Het hele bestand is één transactie (BEGIN … COMMIT): faalt er iets, dan
-- wordt er niets toegepast en blijft de database op de staat van 009 staan.
--
-- PROBLEEM
-- Tot nu toe legde alleen de app (deleteShift) een exception vast bij het
-- verwijderen van een roosterconcept. Een rauwe SQL-delete — of een toekomstig
-- pad dat niet via de app loopt — liet de dienst bij de volgende generatie
-- gewoon terugkomen. Deze trigger dekt ÁLLE verwijderpaden.
--
-- UITZONDERING
-- Systeem-opschoning (roosterregel deactiveren/wijzigen) verwijdert óók
-- concepten en mag géén exception achterlaten — anders zou een gewijzigde regel
-- zichzelf permanent blokkeren op elke datum die hij ooit had.
--
-- WAAROM DE VLAG DE TRANSACTIE-ID IS, EN GEEN 'on'
-- De suppressievlag is een GUC (`app.suppress_schedule_exception`). Een GUC
-- leeft in de sessie, en Supabase zet PostgREST achter een pooler die sessies
-- hergebruikt voor andere requests. Een booleaanse 'on' die om welke reden dan
-- ook blijft hangen, zou dus in een wildvreemd verzoek stilzwijgend exceptions
-- onderdrukken — de stilste bug die dit ontwerp kan hebben.
-- Daarom is de waarde géén 'on' maar `pg_current_xact_id()`. De trigger
-- onderdrukt alleen als de opgeslagen waarde gelijk is aan de transactie-id van
-- de transactie waarin híj draait. Dat geeft twee onafhankelijke sloten:
--   1. `set_config(..., is_local => true)` → de waarde verdwijnt sowieso bij
--      het einde van de transactie (commit én rollback);
--   2. zelfs áls de waarde toch in de sessie zou blijven staan, hoort hij bij
--      een transactie die niet meer bestaat → de volgende transactie heeft een
--      andere id en de vlag doet niets meer.
-- Slot 2 is het slot dat niet van een conventie afhangt. Zie de test in
-- supabase/tests/010_schedule_exception_trigger_test.sql (geval D).
-- ════════════════════════════════════════════════════════════════════════

BEGIN;


-- ────────────────────────────────────────────────────────────────────────
-- 1. Trigger: bij delete van een roosterdienst → exception vastleggen,
--    tenzij deze transactie zichzelf als systeem-opschoning heeft gemarkeerd.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.record_schedule_exception_on_delete()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  -- Losse (niet-rooster)diensten: niets te doen. Deze afslag staat bewust
  -- vóór pg_current_xact_id(), zodat de verreweg meest voorkomende delete
  -- geen enkel extra werk kost.
  IF OLD.schedule_id IS NULL THEN
    RETURN OLD;
  END IF;

  -- Onderdrukken alleen als de vlag bij DEZE transactie hoort. current_setting
  -- met missing_ok geeft NULL als de vlag nooit gezet is; COALESCE naar '' maakt
  -- de vergelijking eenduidig (pg_current_xact_id() is nooit leeg).
  IF COALESCE(current_setting('app.suppress_schedule_exception', true), '')
     = pg_current_xact_id()::text
  THEN
    RETURN OLD;
  END IF;

  INSERT INTO public.schedule_exceptions (schedule_id, exception_date)
  VALUES (OLD.schedule_id, OLD.shift_date)
  ON CONFLICT (schedule_id, exception_date) DO NOTHING;

  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS trg_schedule_exception_on_delete ON public.shifts;
CREATE TRIGGER trg_schedule_exception_on_delete
  AFTER DELETE ON public.shifts
  FOR EACH ROW EXECUTE FUNCTION public.record_schedule_exception_on_delete();


-- ────────────────────────────────────────────────────────────────────────
-- 2. Systeem-opschoning: verwijdert de toekomstige concepten van een regel
--    ZONDER exception. Vervangt de directe client-delete in scheduleService.
--    Zelfde vorm als generate_schedule_shifts (009): SECURITY DEFINER met
--    vaste search_path en een expliciete planner-guard, omdat EXECUTE op
--    functies in Postgres standaard aan PUBLIC toekomt.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.remove_future_schedule_drafts(p_schedule_id UUID)
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_deleted INT;
BEGIN
  IF NOT public.is_privileged() THEN
    RAISE EXCEPTION 'Alleen planners mogen roosterconcepten opschonen.';
  END IF;

  -- is_local => true: geldt alleen binnen deze transactie. De waarde is de
  -- transactie-id, zodat een eventueel achtergebleven waarde in een volgende
  -- transactie niet meer matcht (zie de kop van dit bestand).
  PERFORM set_config('app.suppress_schedule_exception',
                     pg_current_xact_id()::text, true);

  DELETE FROM public.shifts
  WHERE schedule_id = p_schedule_id
    AND status = 'draft'
    AND shift_date >= current_date;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  -- Meteen weer leeg: als deze functie in een grotere transactie wordt
  -- aangeroepen, mag een latere delete in diezelfde transactie niet meeliften
  -- op de vlag. (Faalt de DELETE, dan sneuvelt de hele transactie inclusief de
  -- vlag — daarom is hier geen EXCEPTION-blok nodig.)
  PERFORM set_config('app.suppress_schedule_exception', '', true);

  RETURN v_deleted;
END;
$$;


COMMIT;
