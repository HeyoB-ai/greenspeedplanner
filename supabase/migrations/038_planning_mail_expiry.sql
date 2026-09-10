-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — leeftijdscontrole voor planningsberichten — 038
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 016 en 019 eerst.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien, en draai daarna       │
-- │ supabase/tests/038_planning_mail_expiry_test.sql.                      │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAAROM — EEN OMISSIE UIT 019, GEEN KEUZE
--   Migratie 019 bouwde declaration_expire_stale() voor het nabericht en filterde
--   dat hard op kind = 'shift_followup'. De oudere soorten uit 016 zijn er nooit
--   in meegenomen. Gevolg: een planningsbericht dat blijft liggen — een dichte
--   allowlist, een koerier zonder adres, een verzender die een tijd stilstond —
--   blijft VOOR ALTIJD op 'pending' staan en gaat uit zodra de poort opengaat.
--
--   Dat is niet theoretisch. Waargenomen: één koerier kreeg één mail met twee
--   blokken over dezelfde dienst — bovenaan "Je bent ingepland op dinsdag 08-09"
--   (eerder ingeschreven, nooit verstuurd) en daaronder "Je dienst van dinsdag
--   08-09 zit erop". Tegenstrijdig, en het onderwerp viel terug op de verzamelnaam
--   "Je planning is bijgewerkt", waardoor de declaratievraag onzichtbaar werd.
--
--   mail_is_upcoming() staat alleen bij het INSCHRIJVEN (016, punt 11); bij het
--   versturen wordt hij niet opnieuw gecontroleerd, en mail_pending_couriers()
--   (017) heeft geen enkel leeftijdsfilter. Deze migratie vult dat gat.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;


-- ────────────────────────────────────────────────────────────────────────
-- 1. mail_expire_stale_planning — wat er wél en niet onder valt.
--
--    WEL: 'shift_confirmed' en 'shift_changed'.
--    Die zeggen "je wordt hier verwacht". Zodra de dienst begonnen is, is dat geen
--    mededeling meer maar ruis: de koerier staat er of hij staat er niet, en een
--    mail kan daar niets meer aan veranderen. De maatstaf is mail_is_upcoming(),
--    dezelfde uitdrukking waarmee de rij is ingeschreven — één definitie van
--    "staat nog te gebeuren" in het hele systeem.
--
--    De payload draagt shifts[] en dat is precies wat we nodig hebben: dat lijstje
--    is bij het inschrijven gevuld met alleen de toen nog toekomstige diensten
--    (016, in mail_payload_for), dus voor een losse dienst staat er precies één in.
--    Is er geen enkele meer die nog moet beginnen, dan is het bericht leeg
--    geworden.
--
--    NIET: 'shift_cancelled'. Bewuste uitzondering, en de belangrijkste beslissing
--    in dit bestand. "Deze dienst vervalt, je hoeft niet te komen" is over een
--    dienst van gisteren nutteloos als planning, maar het is wél het bewijs dát er
--    gemeld is — en een koerier die niets hoort over een geannuleerde dienst gaat
--    er misschien alsnog heen. Een late afmelding is goedkoper dan een koerier
--    voor een dichte deur. Deze berichten gaan dus altijd uit, hoe oud ook.
--
--    NIET: 'schedule_*' zonder einddatum. Een afspraak gaat over een doorlopend
--    rooster en heeft geen begintijd die verstrijkt. De losse datums in shifts[]
--    zijn hier NIET de horizon, en dat is expres: de vingerafdruk bevat geen
--    datums, dus de afspraak loopt door voorbij wat er in het lijstje staat. Zo'n
--    bericht wordt daarmee onvolledig en niet onwaar — en dat is precies waarom de
--    peildatum bovenaan de mail staat.
--
--    WEL: 'schedule_confirmed' en 'schedule_changed' MET een einddatum die voorbij
--    is. Dan is de afspraak zelf afgelopen en is het bericht niet meer onvolledig
--    maar onwaar: er is niets meer om vast ingepland voor te staan. end_date is
--    nullable, dus dit dekt alleen de afspraken waar hij gezet is; een open
--    afspraak blijft buiten de controle en dat is de bedoeling.
--
--    NIET: 'schedule_cancelled'. Die soort is nog niet in gebruik (zie de CHECK in
--    016) en meldt het einde van een afspraak — er is geen moment waarop dat
--    onwaar wordt.
--
--    NIET: 'shift_followup' en 'declaration_reminder'. Die hebben hun eigen
--    controle in declaration_expire_stale() (019/036), met max_age_days als
--    maatstaf in plaats van de starttijd. Twee functies, twee domeinen, geen
--    overlap — zo blijft achteraf te zien welke controle een rij heeft afgesloten.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.mail_expire_stale_planning()
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE v_rows INT;
BEGIN
  UPDATE public.mail_outbox o
     SET status = 'expired',
         error  = CASE
                    WHEN o.kind IN ('shift_confirmed', 'shift_changed')
                      THEN 'de dienst is al begonnen'
                    ELSE format('de afspraak is op %s afgelopen', o.payload->>'end_date')
                  END
   WHERE o.status = 'pending'
     AND (
       (
         o.kind IN ('shift_confirmed', 'shift_changed')
         -- Een LEGE lijst valt hier bewust buiten. Die levert een bericht zonder
         -- inhoud op en wordt door de verzender al afgesloten met zijn eigen reden
         -- ("geen inhoud om te versturen"). Hem hier op 'expired' zetten zou die
         -- reden overschrijven met een bewering over diensten die er niet in staan.
         AND jsonb_array_length(COALESCE(o.payload->'shifts', '[]'::jsonb)) > 0
         AND NOT EXISTS (
           SELECT 1
           FROM jsonb_array_elements(o.payload->'shifts') AS e
           WHERE public.mail_is_upcoming(
                   (e->>'shift_date')::DATE,
                   (e->>'start_time')::TIME)
         )
       )
       OR
       (
         o.kind IN ('schedule_confirmed', 'schedule_changed')
         AND o.payload->>'end_date' IS NOT NULL
         AND (o.payload->>'end_date')::DATE < current_date
       )
     );

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$fn$;

COMMENT ON FUNCTION public.mail_expire_stale_planning() IS
  'Sluit planningsberichten af die niet meer waar kunnen worden (migratie 038): '
  'shift_confirmed/shift_changed zodra de dienst begonnen is, en '
  'schedule_confirmed/schedule_changed zodra de einddatum voorbij is. '
  'shift_cancelled valt er bewust buiten en gaat altijd uit.';


-- ────────────────────────────────────────────────────────────────────────
-- 2. Rechten — uitsluitend voor de verzender.
-- ────────────────────────────────────────────────────────────────────────
REVOKE ALL     ON FUNCTION public.mail_expire_stale_planning() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mail_expire_stale_planning() TO service_role;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie — kijk hier naar VOORDAT je COMMIT doet.
--   1. Wat er zou afvallen, per soort. Dit is de belangrijkste query: staan er
--      tientallen, dan heeft de verzender langer stilgestaan dan je dacht en wil
--      je eerst weten waarom.
--   2. De hele wachtrij per soort, zodat je ziet dat shift_cancelled blijft staan.
--   3. Daarna één keer echt uitvoeren en het aantal terugkrijgen.
-- ────────────────────────────────────────────────────────────────────────
SELECT o.kind,
       count(*) AS gaat_op_expired,
       min(o.created_at) AS oudste,
       min(o.payload->>'end_date') AS oudste_einddatum
FROM public.mail_outbox o
WHERE o.status = 'pending'
  AND (
    (o.kind IN ('shift_confirmed', 'shift_changed')
     AND jsonb_array_length(COALESCE(o.payload->'shifts', '[]'::jsonb)) > 0
     AND NOT EXISTS (
       SELECT 1 FROM jsonb_array_elements(o.payload->'shifts') AS e
       WHERE public.mail_is_upcoming((e->>'shift_date')::DATE, (e->>'start_time')::TIME)))
    OR
    (o.kind IN ('schedule_confirmed', 'schedule_changed')
     AND o.payload->>'end_date' IS NOT NULL
     AND (o.payload->>'end_date')::DATE < current_date)
  )
GROUP BY o.kind
ORDER BY o.kind;

SELECT kind, count(*) AS blijft_pending
FROM public.mail_outbox
WHERE status = 'pending'
GROUP BY kind
ORDER BY kind;

SELECT public.mail_expire_stale_planning() AS afgesloten;

COMMIT;   -- vervang door ROLLBACK; voor een dry-run zonder op te slaan
