-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — verzendkant van de bevestigingsmail — migratie 017
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 016 eerst. Deze migratie voegt alleen toe wat de Edge Function
-- nodig heeft om de outbox te verwerken; 016 blijft ongemoeid.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien.                       │
-- └────────────────────────────────────────────────────────────────────────┘
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────
-- 1. mail_recipient_for — het adres van een koerier.
--    Bron is auth.users; courier_contacts.email_override gaat er vóór als het
--    inlogadres geen werkende postbus is. Bewust GEEN kopie van het adres in een
--    eigen tabel: dat is de spiegel die migratie 008 al een keer heeft
--    afgestraft (user_profiles.pharmacy_ids liep uiteen met de werkelijkheid).
--
--    Dit is de ENIGE plek in het project die auth.users leest. Supabase kan dat
--    schema tussen versies wijzigen; door de afhankelijkheid hier op te sluiten
--    is er één bestand om aan te passen als dat gebeurt.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.mail_recipient_for(p_courier_id UUID)
RETURNS TABLE (email TEXT, source TEXT, confirmed BOOLEAN)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT
    COALESCE(cc.email_override, au.email)::TEXT,
    CASE WHEN cc.email_override IS NOT NULL THEN 'override' ELSE 'login' END,
    au.email_confirmed_at IS NOT NULL
  FROM auth.users au
  LEFT JOIN public.courier_contacts cc ON cc.courier_id = au.id
  WHERE au.id = p_courier_id;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 2. mail_pending_couriers — wie heeft er post klaarstaan.
--    Eén rij per koerier, met het aantal en het oudste bericht, zodat de
--    verzender per koerier kan bundelen (punt 9 van het ontwerp).
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.mail_pending_couriers()
RETURNS TABLE (courier_id UUID, courier_name TEXT, items INT, oldest TIMESTAMPTZ)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT o.courier_id, up.name, count(*)::INT, min(o.created_at)
  FROM public.mail_outbox o
  JOIN public.user_profiles up ON up.id = o.courier_id
  WHERE o.status = 'pending'
  GROUP BY o.courier_id, up.name
  ORDER BY min(o.created_at);
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 3. mail_claim_for_courier — claim-dan-versturen, voor een hele bundel.
--    Eén UPDATE-statement: alle wachtende berichten van deze koerier gaan in
--    één keer naar 'sending'. Daardoor is er geen half geclaimde bundel, ook
--    niet als er twee verzenders tegelijk draaien — de tweede krijgt nul rijen.
--
--    Blijft een bundel op 'sending' hangen (proces gestorven tussen claimen en
--    versturen), dan gaat er voor die berichten niets meer uit. Fail-closed en
--    zichtbaar, zoals bij de SMS: liever een gemiste mail die je in de outbox
--    ziet staan dan een dubbele bij de koerier.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.mail_claim_for_courier(p_courier_id UUID)
RETURNS SETOF public.mail_outbox
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  UPDATE public.mail_outbox
     SET status = 'sending', claimed_at = now()
   WHERE courier_id = p_courier_id
     AND status = 'pending'
  RETURNING *;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 4. mail_record_result — uitkomst van de provider op de hele bundel.
--    Eén bericht per bundel, dus één uitkomst voor alle rijen erin. recipient
--    wordt hier vastgelegd: het adres wordt bij het verzenden bepaald, niet bij
--    het inschrijven, zodat een gecorrigeerd adres nog doorwerkt op post die al
--    klaarstond.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.mail_record_result(
  p_ids UUID[], p_ok BOOLEAN, p_recipient TEXT,
  p_message_id TEXT DEFAULT NULL, p_error TEXT DEFAULT NULL
)
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rows INT;
BEGIN
  UPDATE public.mail_outbox
     SET status              = CASE WHEN p_ok THEN 'sent' ELSE 'failed' END,
         recipient           = p_recipient,
         provider_message_id = p_message_id,
         error               = p_error,
         sent_at             = CASE WHEN p_ok THEN now() ELSE NULL END
   WHERE id = ANY (p_ids);
  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 5. Rechten — uitsluitend voor de job. EXECUTE staat standaard aan voor
--    PUBLIC en deze functies omzeilen als SECURITY DEFINER de RLS;
--    mail_recipient_for zou anders e-mailadressen prijsgeven.
-- ────────────────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.mail_recipient_for(UUID)                        FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mail_pending_couriers()                         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mail_claim_for_courier(UUID)                    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mail_record_result(UUID[], BOOLEAN, TEXT, TEXT, TEXT) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.mail_recipient_for(UUID)                     TO service_role;
GRANT EXECUTE ON FUNCTION public.mail_pending_couriers()                      TO service_role;
GRANT EXECUTE ON FUNCTION public.mail_claim_for_courier(UUID)                 TO service_role;
GRANT EXECUTE ON FUNCTION public.mail_record_result(UUID[], BOOLEAN, TEXT, TEXT, TEXT) TO service_role;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie — verwacht: vier functies, alle vier SECURITY DEFINER, en geen
-- EXECUTE voor anon/authenticated.
-- ────────────────────────────────────────────────────────────────────────
SELECT p.proname, p.prosecdef AS security_definer
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('mail_recipient_for', 'mail_pending_couriers',
                    'mail_claim_for_courier', 'mail_record_result')
ORDER BY p.proname;

SELECT routine_name, grantee, privilege_type
FROM information_schema.routine_privileges
WHERE routine_schema = 'public' AND routine_name LIKE 'mail/_%' ESCAPE '/'
  AND grantee IN ('anon', 'authenticated')
ORDER BY routine_name, grantee;   -- verwacht: geen rijen

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
