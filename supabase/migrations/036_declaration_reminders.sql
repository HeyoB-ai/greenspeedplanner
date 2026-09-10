-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — herinneringen voor openstaande declaraties — 036
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 019 (nadeclaratie-mail) en 031 (meerwerk) eerst.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien, en draai daarna       │
-- │ supabase/tests/036_declaration_reminders_test.sql.                     │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAAROM
--   De invullink gaat van 30 naar 5 dagen. Twee redenen: de rapportage naar de
--   opdrachtgever moet sneller rond zijn, en wie pas na een week invult gokt de
--   tijden — dat kost meerwerk dat achteraf niet meer te factureren is.
--
--   Een kortere termijn alléén maakt dat tweede juist erger: dezelfde koerier
--   heeft dan minder tijd om alsnog te gokken. Daarom komt er in dezelfde
--   beweging ruimte voor herinneringen. Deze migratie legt het fundament — de
--   instellingen, de berichtsoort en de logtabel. Wie er een herinnering krijgt
--   en langs welk kanaal, staat hier bewust nog niet in.
--
-- BESTAANDE LINKS GAAN MEE OMLAAG
--   token_expires_at wordt bij het AANMAKEN van de declaratie vastgelegd
--   (migratie 019, punt 4) en niet bij elk gebruik opnieuw uit de instelling
--   gelezen. Zonder punt 1b zouden bestaande declaraties dus hun 30 dagen
--   houden.
--
--   Dat gebeurt hier bewust wél. Alles staat nog in test: er liggen geen links
--   in mailboxen van echte koeriers, dus er valt niets stuk te maken. En wat
--   overblijft is het argument ervóór — twee termijnen naast elkaar is
--   verwarrender dan één. Een declaratie van vorige week zou anders nog drie
--   weken open blijven staan terwijl alles wat er vandaag bij komt na vijf dagen
--   dichtgaat, en dan klopt geen enkele uitspraak over "de termijn" meer.
--
--   ⚠ HERHAAL DIT NIET OP EEN OMGEVING MET ECHTE KOERIERS. Punt 1b doodt per
--   direct elke link van een dienst die langer dan token_valid_days geleden was
--   — inclusief die van iemand die hem vanmiddag nog had willen gebruiken.
--   Verificatiequery 4 telt hoeveel dat er zijn vóór je COMMIT doet.
--
-- ⚠ max_age_days GAAT MEE OMLAAG, EN DAT RUIMT METEEN OP
--   Zie punt 1 voor het waarom. Gevolg: wachtende naberichten over diensten van
--   langer dan 4 dagen geleden gaan bij de eerstvolgende verzendronde op
--   'expired'. Met de oude 14 kunnen dat er een paar zijn. Verificatiequery 3
--   onderaan telt ze vóór je COMMIT doet — kijk daar eerst naar.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;


-- ────────────────────────────────────────────────────────────────────────
-- 1. De twee termijnen, en waarom ze bij elkaar horen.
--
--    token_valid_days = hoe lang de invullink werkt, geteld vanaf de DIENSTDATUM.
--    max_age_days     = hoe lang een wachtend nabericht nog de deur uit mag.
--
--    Zolang 30 > 14 kon dat niet knellen. Zou token_valid_days naar 5 gaan en
--    max_age_days op 14 blijven staan, dan ontstaat er een venster van negen
--    dagen waarin een outbox-rij nog niet verlopen is maar
--    declaration_issue_token() al weigert ("de invullink van declaratie % is
--    verlopen", migratie 019, punt 6). De verzender krijgt dan geen link, zet de
--    rij met declaration_release() terug op 'pending' en schrijft een foutregel.
--    Elke run opnieuw, negen dagen lang, zonder dat er ooit iets uitgaat.
--
--    4 en niet 5: dan heeft een bericht dat nog mag uitgaan altijd een link die
--    daarna nog minstens een dag werkt. Gelijk zetten zou betekenen dat een mail
--    op de valreep een link kan dragen die diezelfde nacht al dood is.
-- ────────────────────────────────────────────────────────────────────────
UPDATE public.declaration_settings
   SET token_valid_days = 5,
       max_age_days     = 4
 WHERE id;


-- ────────────────────────────────────────────────────────────────────────
-- 1b. Bestaande invullinks meenemen in de nieuwe termijn.
--
--     Ná punt 1, zodat hier de ZOJUIST gezette waarde gelezen wordt. Het getal
--     staat daarom nergens in deze query: wie hierboven een andere termijn
--     invult dan 5, krijgt hem hier automatisch mee. Twee plekken die allebei
--     "5" zeggen lopen vroeg of laat uiteen.
--
--     Dezelfde uitdrukking als declaration_sweep() bij het aanmaken gebruikt
--     (migratie 019, punt 4): geteld vanaf de DIENSTDATUM, om middernacht
--     Europe/Amsterdam. De join naar shifts is nodig omdat shift_date daar staat
--     en niet op de declaratie zelf.
--
--     Alleen 'open' en 'submitted'. Bij 'approved' en 'disputed' valt er niets
--     meer in te vullen; de link toont dan nog een leesweergave (migratie 023),
--     en die onnodig afknijpen zou een koerier het zicht op zijn eigen opgave
--     ontnemen zonder dat het iets oplevert.
-- ────────────────────────────────────────────────────────────────────────
UPDATE public.shift_declarations d
   SET token_expires_at =
         (s.shift_date + c.token_valid_days)::TIMESTAMP AT TIME ZONE 'Europe/Amsterdam'
  FROM public.shifts s,
       public.declaration_settings c
 WHERE s.id = d.shift_id
   AND c.id
   AND d.status IN ('open', 'submitted');


-- ────────────────────────────────────────────────────────────────────────
-- 2. mail_outbox: 'declaration_reminder' erbij.
--
--    Sinds migratie 019 heeft de constraint een eigen naam, dus de zoektocht
--    door pg_constraint die 019 en 031 nog moesten doen is hier niet meer nodig
--    — die was er alleen omdat 016 de CHECK inline had gezet en Postgres hem
--    zelf een naam gaf. Verruimen kan niet stuklopen op bestaande rijen: die
--    vallen allemaal binnen de nieuwe verzameling.
--
--    De soort staat er alvast, ook al maakt nog niets zulke rijen. Zonder deze
--    stap kan de verzendkant er straks niet bij, en dit is de goedkoopste helft
--    van het hele plan.
-- ────────────────────────────────────────────────────────────────────────
ALTER TABLE public.mail_outbox
  DROP CONSTRAINT IF EXISTS mail_outbox_kind_chk;

ALTER TABLE public.mail_outbox
  ADD CONSTRAINT mail_outbox_kind_chk CHECK (kind IN (
    'schedule_confirmed', 'schedule_changed', 'schedule_cancelled',
    'shift_confirmed',    'shift_changed',    'shift_cancelled',
    'shift_followup',     'extra_work_request',
    'declaration_reminder'));


-- ────────────────────────────────────────────────────────────────────────
-- 3. declaration_reminders — welke herinnering er al uit is.
--
--    Dezelfde opzet als shift_sms_log (migratie 012), en om dezelfde reden: de
--    logrij wordt geschreven VÓÓRDAT de provider wordt aangeroepen, en de
--    primary key is de idempotentie. Claimen is dus:
--
--        INSERT INTO public.declaration_reminders (declaration_id, stage)
--        VALUES (…, …)
--        ON CONFLICT DO NOTHING;
--
--    ROW_COUNT = 0 betekent dat een andere run ons voor was → overslaan, niet
--    opnieuw proberen. Een dubbele herinnering is duurder dan een gemiste: de
--    eerste kost vertrouwen, de tweede kost één opgave die je alsnog kunt
--    najagen.
--
--    WAAROM (declaration_id, stage) EN NIET declaration_id ALLEEN
--    Dat is precies de val waar shift_sms_log in zit: die heeft shift_id als
--    primary key, waardoor er per dienst nooit een tweede bericht uit kán. Met
--    stage erbij is elke stap zijn eigen claim, en legt de CHECK vast dat er maar
--    twee stappen bestaan. "Nooit meer dan twee" is daarmee een schemagarantie
--    en geen afspraak in code die iemand later per ongeluk versoepelt.
--
--    status 'sending' = geclaimd, provider nog niet bevestigd. Blijft een rij zo
--    staan, dan is het proces tussen claimen en versturen gestorven: er is niets
--    uitgegaan én er komt niets meer. Fail-closed, dezelfde keuze als bij de SMS
--    (012) en de mail (017).
--
--    ON DELETE CASCADE: verdwijnt de declaratie omdat de dienst verwijderd is
--    (shift_declarations hangt zelf ook aan shifts met CASCADE, migratie 018),
--    dan heeft deze log geen betekenis meer.
--
--    Bewust NIET in deze tabel: naar welk adres of nummer het ging, en langs welk
--    kanaal. Dat hangt af van hoe de herinnering verstuurd wordt, en dat is nog
--    niet vastgesteld. Een kolom die je nu invult op een aanname is duurder dan
--    een kolom die je later toevoegt.
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.declaration_reminders (
  declaration_id      UUID NOT NULL
                      REFERENCES public.shift_declarations(id) ON DELETE CASCADE,

  -- 1 = eerste herinnering, 2 = tweede en laatste. Een getal en geen naam, zodat
  -- "de zoveelste" ook sorteert en een derde stap niet stilletjes kan ontstaan.
  stage               SMALLINT NOT NULL CHECK (stage IN (1, 2)),

  status              TEXT NOT NULL DEFAULT 'sending'
                      CHECK (status IN ('sending', 'sent', 'failed')),

  -- Wat de provider terugmeldde. Zonder dit is een bericht dat volgens ons
  -- verstuurd is en volgens de koerier nooit aankwam, niet na te trekken.
  provider_message_id TEXT,
  error               TEXT,

  claimed_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  sent_at             TIMESTAMPTZ,

  PRIMARY KEY (declaration_id, stage)
);

COMMENT ON TABLE public.declaration_reminders IS
  'Herinneringen voor openstaande nadeclaraties (migratie 036). Eén rij per '
  '(declaratie, stap); de primary key is de idempotentie, de CHECK op stage is '
  'de bovengrens van twee. Schrijven doet uitsluitend de job.';


-- ────────────────────────────────────────────────────────────────────────
-- 4. RLS — planners lezen mee, niemand schrijft.
--    Zelfde verdeling als shift_sms_log: de status hoort zichtbaar te zijn in de
--    planner, want het echte risico van een nachtelijke job is niet een
--    overgeslagen run maar een job die maanden geleden stilletjes gestopt is.
--    Schrijven gebeurt met de service-role key, die RLS omzeilt; een schrijf-
--    policy zou alleen maar een tweede weg naar binnen openen.
-- ────────────────────────────────────────────────────────────────────────
ALTER TABLE public.declaration_reminders ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "declaration_reminders_privileged_read"
  ON public.declaration_reminders;
CREATE POLICY "declaration_reminders_privileged_read"
  ON public.declaration_reminders
  FOR SELECT USING (public.is_privileged());

-- Zie migratie 018, punt 10: zonder GRANT struikelt een planner op "permission
-- denied" nog vóór de policy bekeken wordt.
GRANT SELECT ON public.declaration_reminders TO authenticated;


-- ────────────────────────────────────────────────────────────────────────
-- 5. declaration_expire_stale — de leeftijdscontrole kent de nieuwe soort.
--
--    Body letterlijk uit migratie 019, punt 5, met één verruimd filter. Zonder
--    deze stap zou een herinnering die om wat voor reden dan ook blijft liggen
--    NOOIT verlopen: het filter stond hard op kind = 'shift_followup', dus een
--    wachtende herinnering bleef bij elke run opnieuw langskomen.
--
--    ⚠ AFHANKELIJKHEID VOOR DE VERZENDKANT
--    De vergelijking is (payload->>'shift_date')::DATE. Ontbreekt shift_date in
--    de payload van een 'declaration_reminder', dan is die uitdrukking NULL, is
--    de vergelijking NULL, en valt de rij nooit binnen de UPDATE — precies het
--    eeuwige-wachtrij-probleem dat deze stap moest oplossen. Elke herinnerings-
--    rij MOET dus shift_date in zijn payload hebben.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.declaration_expire_stale()
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_cfg  public.declaration_settings;
  v_rows INT;
BEGIN
  SELECT * INTO v_cfg FROM public.declaration_settings WHERE id;

  UPDATE public.mail_outbox
     SET status = 'expired',
         error  = format('dienst is ouder dan %s dagen', v_cfg.max_age_days)
   WHERE kind   IN ('shift_followup', 'declaration_reminder')
     AND status = 'pending'
     AND (payload->>'shift_date')::DATE < current_date - v_cfg.max_age_days;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 6. declaration_release — een geclaimde herinnering kan ook terug.
--
--    Body letterlijk uit migratie 019, punt 5b, met hetzelfde verruimde filter.
--    De verzender claimt de hele bundel van een koerier in één UPDATE en legt
--    daarna één uitkomst op alle rijen vast; een rij waarvoor geen bruikbaar
--    bericht te maken was moet daarom terug naar 'pending' in plaats van als
--    'sent' mee te liften. Zonder deze verruiming zou een herinnering zonder
--    link op 'sending' blijven staan — geen bericht, en ook geen tweede kans.
--
--    (031 heeft hiervoor mail_release(), dat helemaal niet op soort filtert.
--    Deze functie houdt zijn filter wél, want hij hoort bij de declaratieketen
--    en mag geen meerwerkmelding aanraken die toevallig in dezelfde bundel zit.)
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.declaration_release(p_ids UUID[])
RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_rows INT;
BEGIN
  UPDATE public.mail_outbox
     SET status = 'pending', claimed_at = NULL
   WHERE id = ANY (p_ids)
     AND kind   IN ('shift_followup', 'declaration_reminder')
     AND status = 'sending';

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  RETURN v_rows;
END;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 7. Rechten. CREATE OR REPLACE laat de bestaande ACL staan; dit is een
--    herhaling van migratie 019, zodat dit bestand op zichzelf klopt.
-- ────────────────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.declaration_expire_stale()  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.declaration_release(UUID[]) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.declaration_expire_stale()  TO service_role;
GRANT EXECUTE ON FUNCTION public.declaration_release(UUID[]) TO service_role;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie — kijk hier naar VOORDAT je COMMIT doet.
--   1. De twee termijnen staan op 5 en 4.
--   2. De berichtsoort is toegevoegd en de rest staat er nog.
--   3. Hoeveel wachtende naberichten er straks op 'expired' gaan door de nieuwe
--      max_age_days. Nul is prettig; een handvol is te verwachten. Staan er
--      tientallen, dan heeft de verzender langer stilgestaan dan je dacht en wil
--      je eerst weten waarom.
--   4. Wat punt 1b heeft geraakt: hoeveel declaraties zijn ingekort, wat de
--      nieuwe vroegste en laatste vervaldatum zijn, en hoeveel er per direct
--      verlopen zijn omdat hun dienst al langer dan token_valid_days geleden
--      was. Dat laatste getal is de prijs van het inkorten — op een omgeving
--      met echte koeriers zou dit het aantal doodgemaakte links zijn.
--   5. De nieuwe tabel: één policy, en de bovengrens van twee.
-- ────────────────────────────────────────────────────────────────────────
SELECT token_valid_days, max_age_days, expected_within_hours, active_from
FROM public.declaration_settings;

SELECT pg_get_constraintdef(oid) AS kind_constraint
FROM pg_constraint
WHERE conrelid = 'public.mail_outbox'::regclass AND conname = 'mail_outbox_kind_chk';

SELECT count(*) AS gaat_op_expired
FROM public.mail_outbox
WHERE kind IN ('shift_followup', 'declaration_reminder')
  AND status = 'pending'
  AND (payload->>'shift_date')::DATE < current_date - 4;

SELECT count(*)                                        AS ingekort,
       count(*) FILTER (WHERE token_expires_at <= now()) AS nu_al_verlopen,
       count(*) FILTER (WHERE token_expires_at >  now()) AS nog_geldig,
       min(token_expires_at)                            AS vroegste_vervaldatum,
       max(token_expires_at)                            AS laatste_vervaldatum
FROM public.shift_declarations
WHERE status IN ('open', 'submitted');

SELECT c.relname, c.relrowsecurity AS rls_aan,
       (SELECT count(*) FROM pg_policies p
        WHERE p.schemaname = 'public' AND p.tablename = 'declaration_reminders') AS policies
FROM pg_class c
WHERE c.oid = 'public.declaration_reminders'::regclass;

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
