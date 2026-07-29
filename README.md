# Greenspeed Planner

Planningsmodule voor Greenspeed-koeriersdiensten. Aparte React-app met eigen
deploy, maar op **dezelfde Supabase-database** als de bezorgsoftware
(AIrouteplanner).

Stack: React 18 + TypeScript + Vite + Tailwind + Supabase.

## Ontwikkelen

```bash
npm install
cp .env.example .env   # vul VITE_SUPABASE_URL en VITE_SUPABASE_ANON_KEY in
npm run dev
```

`npm run lint` = `tsc --noEmit`, `npm run build` = productie-build.

## Migraties

SQL-bestanden in `supabase/migrations/` draai je **handmatig** in de Supabase
SQL Editor van de gedeelde Greenspeed-database, op volgorde:

| Migratie | Inhoud |
|---|---|
| `001_shift_planning.sql` | `shifts` + koppeltabellen + RLS |
| `002_tighten_rls_quickwins.sql` | RLS-opschoning `pharmacy_codes` / `groups` |
| `003_transport_mode.sql` | `shifts.transport_mode` (bike/car) |
| `004_pharmacy_coords.sql` | `pharmacies."addressLat"/"addressLng"` |
| `005_draft_status.sql` | concept-status `draft` op `shifts` + RLS-afdichting |
| `006_shift_time_reports.sql` | `shift_time_reports` + RLS/trigger + `shifts.car_is_own` |
| `007_timing_reliable.sql` | `shifts.timing_reliable` (kalibratie-markering, default false) |
| `008_cpa_privileged_read.sql` | planner leest volledige `courier_pharmacy_access` (koppelbron) |
| `009_pharmacy_schedules.sql` | roosters per apotheek + feestdagen + generator-RPC + RLS |
| `010_schedule_exception_trigger.sql` | delete-trigger (exception-vangnet) + `remove_future_schedule_drafts` RPC |
| `011_courier_contacts.sql` | telefoonnummers van koeriers (planner-only, aparte tabel) |
| `012_shift_sms_log.sql` | `shift_sms_log` + `sms_due_shifts` / `sms_claim_shift` / `sms_record_result` |
| `013_car_is_own_optional.sql` | car-CHECK vervalt op `shifts` en `pharmacy_schedules`; NULL = nog niet bekend |
| `014_invitations_rls.sql` | RLS op `invitations`: geen publieke tokens meer, aanmaken alleen door bevoegden |
| `015_signup_role_clamp.sql` | registratie levert altijd een koerier op; accounts daarboven maak je zelf aan (zie de kop van de migratie) |
| `016_shift_mail.sql` | bevestigingsmail: `courier_announcements` + `mail_outbox` + `mail_sweep()` + triggers + `email_override` |
| `017_mail_dispatch.sql` | verzendkant: `mail_recipient_for` / `mail_pending_couriers` / `mail_claim_for_courier` / `mail_record_result` |

Migratie 010 is één transactie (`BEGIN … COMMIT`): faalt er iets, dan wordt er
niets toegepast.

### Tests

`supabase/tests/` bevat controles die je ná de bijbehorende migratie in dezelfde
SQL Editor draait. Ze eindigen op `ROLLBACK` en laten niets in de database
achter. Geen foutmelding = geslaagd; elke melding noemt het geval dat faalde.

| Test | Controleert |
|---|---|
| `010_schedule_exception_trigger_test.sql` | levensduur van de suppressievlag + trigger/RPC-gedrag (rauwe delete legt wél een exception vast, de opschoon-RPC niet) |
| `012_sms_log_test.sql` | selectie van de herinnerings-SMS (concept/begonnen/buiten venster/geen nummer) + claim precies één keer + tijdzonegrens |
| `014_invitations_rls_test.sql` | koerier mag geen uitnodiging maken en ziet geen tokens; planner wél, inclusief de returning-select van `inviteUser` |
| `015_signup_role_clamp_test.sql` | `role=superuser` uit metadata wordt courier; `pharmacy_ids` uit metadata genegeerd; zonder rol géén profiel |
| `016_shift_mail_test.sql` | de volledige beslistabel van de sweep: tien donderdagen = één bericht, opnieuw bevestigen is stil, variant erbij én variant weggewijzigd zijn nieuws, versmallen door tijdsverloop niet, afmelding bij verwijderen en bij een koerierwissel |

`014_invitations_rls_test.sql` doet zich voor als een gewone gebruiker met
`SET LOCAL ROLE authenticated`. Zonder die rolwissel draai je als `postgres` en
die omzeilt RLS volledig — de test slaagt dan altijd en bewijst niets.

## Gebruikers aanmaken

Sinds migratie 015 levert **elke registratie via het publieke formulier een
koerier op**, wat er ook in de metadata staat. Alles daarboven — `superuser`,
`supervisor`, `admin` én `pharmacy` — maak je met de hand aan, in twee stappen.

De reden dat het twee stappen zijn: de trigger `on_auth_user_created` vuurt bij
elke nieuwe rij in `auth.users`, ook bij eentje die jij in het dashboard
aanmaakt. De database kan niet zien of een rij van het publieke formulier komt
of van jouw hand — beide zijn een insert in dezelfde tabel, zonder sessie. Wat
wél verschilt is de metadata, en daar zit het pad: **zonder rol in de metadata
maakt de trigger geen profielrij aan**, zodat jij hem daarna zelf zet.

**Stap 1 — account.** Dashboard → Authentication → Add user. E-mailadres en
wachtwoord invullen, "Auto Confirm User" aan, en de **user-metadata leeg laten**
(geen `role`-veld).

**Stap 2 — profiel.** SQL Editor, met de juiste rol:

```sql
INSERT INTO public.user_profiles (id, name, role, pharmacy_ids)
SELECT id, 'Naam van de persoon', 'pharmacy', ARRAY['ph-123']
FROM auth.users WHERE email = 'iemand@apotheek.nl';
```

| Rol | Waarvoor | `pharmacy_ids` |
|---|---|---|
| `superuser` | volledige toegang, planner | leeg `'{}'` |
| `supervisor` | regiomanager, planner | leeg `'{}'` |
| `admin` | apotheker/beheerder van een apotheek | de eigen apotheek/apotheken |
| `pharmacy` | apotheekmedewerker | de eigen apotheek/apotheken |
| `courier` | koerier | leeg — koppelt zichzelf via de koppelcode |

`superuser`, `supervisor` en `admin` zijn de rollen die `is_privileged()` als
planner ziet; die krijgen dus ook toegang tot het plannerscherm.

**Ging het mis?** Zat er tóch een `role` in de metadata, dan is het een koerier
geworden en staat er een `[rol-clamp]`-regel in de Postgres-logs. Rechtzetten:

```sql
UPDATE public.user_profiles SET role = 'pharmacy', pharmacy_ids = ARRAY['ph-123']
WHERE id = '<uuid>';
```

Dat mag: in de SQL Editor draai je als `postgres`, en de kolomrechten die
`role` en `hourlyWage` afschermen gelden voor de rol `authenticated`, niet voor
jou.

**Koeriers** hoef je hier niet aan te maken. Die registreren zichzelf op het
inlogscherm van de bezorg-app en koppelen zich daarna met de koppelcode aan een
apotheek. Staat "Allow new users to sign up" in Supabase Auth uit, dan kan dat
niet en maak je ze op dezelfde manier aan als hierboven, met rol `courier` en
lege `pharmacy_ids`.

## Bevestigingsmail (fase 5) — nog niet in gebruik

Het ontwerp met alle redenen staat in [`docs/FASE5_MAIL_ONTWERP.md`](docs/FASE5_MAIL_ONTWERP.md).
Migratie 016 zet de tabellen, triggers en `mail_sweep()` neer. **De verzender
bestaat nog niet.**

> ⚠️ **Zet de cron voor `mail_sweep()` nog NIET aan.** Zonder verzender lopen de
> `pending`-rijen in `mail_outbox` op, en de eerste verzendrun stuurt dan alles in
> één keer — dezelfde valkuil als de eerste SMS-run. Twee dingen moeten er eerst
> zijn: `MAIL_ALLOWLIST` (zodat er alleen naar jouw eigen adressen gaat zolang het
> testdomein in gebruik is) en de mogelijkheid om de outbox te bekijken.

Draaien van 016 zelf is veilig: de migratie sluit af met een **vulling** die voor
elke al bevestigde dienst een aankondiging inschrijft *zonder* outbox-rijen. Een
eerste `mail_sweep()` levert daarna nul berichten op; alleen wat je ná de migratie
bevestigt of wijzigt komt in de outbox.

Wat er klaarstaat, bekijk je zo:

```sql
SELECT o.created_at, o.kind, up.name AS koerier, o.status,
       o.payload->'shifts' AS diensten, o.payload->>'reason' AS reden
FROM public.mail_outbox o
JOIN public.user_profiles up ON up.id = o.courier_id
WHERE o.status = 'pending'
ORDER BY o.courier_id, o.created_at;
```

Opruimen mag zolang er niets verstuurd is — de sweep schrijft niets terug dat
verloren gaat, maar de aankondiging blijft staan, dus het bericht komt níet
opnieuw:

```sql
DELETE FROM public.mail_outbox WHERE status = 'pending';
```

Wil je de aankondigingen óók terugzetten zodat alles opnieuw gemeld wordt (alleen
tijdens het inregelen zinvol):

```sql
DELETE FROM public.courier_announcements;   -- eerstvolgende sweep meldt alles opnieuw
```

### De verzender

`supabase/functions/send-shift-mail/` leest de outbox, bundelt per koerier en
verstuurt via Brevo. Vereist migratie 017.

Per koerier: **eerst het adres bepalen, dan claimen.** Is er geen adres of staat
het niet op de allowlist, dan wordt er niet geclaimd en blijven de berichten op
`pending` staan — ze gaan gewoon mee zodra het adres er is of de beperking eraf
gaat. Zou je eerst claimen, dan zou zo'n bundel als mislukt eindigen en nooit
meer uitgaan.

| Variabele | Standaard | Waarvoor |
|---|---|---|
| `BREVO_API_KEY` | — | verplicht, behalve in dry run; type `xkeysib-…` |
| `MAIL_FROM` | — | afzenderadres, nu `planning@greenspeedkoeriers.nl` (**mét** s) |
| `MAIL_FROM_NAME` | `Greenspeed Planning` | weergavenaam |
| `MAIL_REPLY_TO` | — | optioneel; antwoorden komen anders op `MAIL_FROM` |
| `MAIL_ALLOWLIST` | — | komma-gescheiden adressen; **gevuld = alleen daarheen**. Leeg = alles gaat uit, en de functie logt dat bij elke run |
| `MAIL_MAX_PER_RUN` | `25` | koeriers per run; overschot komt de volgende run |
| `MAIL_DRY_RUN` | — | `1` = niets claimen, niets versturen |
| `CRON_SECRET` | — | indien gezet, verplicht als header `x-cron-secret` |

Uitrollen:

```powershell
npx supabase secrets set MAIL_FROM=planning@greenspeedkoeriers.nl `
  MAIL_FROM_NAME="Greenspeed Planning" `
  MAIL_ALLOWLIST="jouw@eigenadres.nl"
npx supabase functions deploy send-shift-mail
```

Proefdraaien — laat per koerier het adres, de berichtsoorten, het onderwerp en de
volledige tekst zien, zonder iets te claimen of te versturen:

```powershell
curl -X POST "https://<project-ref>.supabase.co/functions/v1/send-shift-mail?dry_run=1" `
  -H "Authorization: Bearer <service-role-key>" -H "x-cron-secret: <CRON_SECRET>"
```

Cron aanzetten doe je pas als de dry run klopt én `MAIL_ALLOWLIST` staat. Twee
schedules, want de sweep en de verzender zijn losse stappen:

```sql
SELECT cron.schedule('mail-sweep', '*/5 * * * *', $$
  SELECT public.mail_sweep();
$$);

SELECT cron.schedule('mail-send', '2-59/5 * * * *', $$
  SELECT net.http_post(
    url     := 'https://<project-ref>.supabase.co/functions/v1/send-shift-mail',
    headers := jsonb_build_object(
                 'Authorization', 'Bearer <service-role-key>',
                 'x-cron-secret', '<CRON_SECRET>',
                 'Content-Type',  'application/json'),
    body    := '{}'::jsonb);
$$);
```

De verzender loopt twee minuten achter op de sweep, zodat een bundel compleet is
voordat hij verstuurd wordt.

### De zes berichtsoorten

Alle tekst staat op één plek: `renderBlock()` en `subjectFor()` in de functie.
Accentloos, en per blok staat er wat de koerier moet doen of weten. Een bundel
krijgt één aanhef en één afsluiting, met een blok per feit in de volgorde waarin
ze ontstonden.

| Soort | Onderwerp | Kern van het blok |
|---|---|---|
| `schedule_confirmed` | Je vaste dienst staat vast | `Je staat vast ingepland:` + een regel per variant met ingangsdatum |
| `schedule_changed` | Je vaste dienst is gewijzigd | `Dit staat er nu:` + alle varianten; de eerdere afgebakend (`van … t/m …`), de laatste open (`vanaf …`) |
| `shift_confirmed` | Je bent ingepland op \<dag\> \<datum\> | `Je bent ingepland op donderdag 30-07-2026, 19:12-21:00 bij X, met de auto.` |
| `shift_changed` | Je dienst van \<dag\> \<datum\> is gewijzigd | `Dit staat er nu: …` |
| `shift_cancelled` | Je dienst van … vervalt / gaat naar een andere koerier | `Deze dienst vervalt: … Je hoeft niet te komen.` |
| `schedule_cancelled` | Je vaste dienst vervalt | nog niet in gebruik; staat er zodat een onbekend feit geen lege mail oplevert |

## Scripts

Eenmalige/beheerscripts in `scripts/`. Ze praten met de gedeelde database via de
**service-role key** en horen dus lokaal gedraaid te worden, nooit in de
clientbundle. De service-role key komt uit het Supabase-dashboard
(Settings → API) of de Netlify-env van de bezorg-app.

### `backfill-pharmacy-coords.mjs` — apotheken geocoden (fase 1)

Vult `pharmacies."addressLat"/"addressLng"` voor apotheken die nog geen
coördinaten hebben. Idempotent, rate-limited, met automatische kwaliteitscontrole
(zie het script). Verdachte geocodes worden **niet** weggeschreven maar in
`scripts/pharmacy-geocode-review.json` gezet voor handmatige controle.

```powershell
# vanuit de projectmap
$env:SUPABASE_SERVICE_ROLE_KEY="<service-role-key>"
$env:GOOGLE_MAPS_API_KEY="<google-geocoding-key>"
node scripts/backfill-pharmacy-coords.mjs
```

Draai 004 vóór dit script. Herhaal de run wanneer er nieuwe apotheken bijkomen.

### `calibrate-timesheets.ts` — kalibratie diensttijd (fase 2)

Draait het rekenmodel (`src/timesheet/computeShiftTime.ts`, puur) over de
afgeronde diensten en rapporteert de verdeling: hoeveel voorstellen, hoeveel
`disputed` en waarom, berekende duur t.o.v. `budgeted_end_time`, de spreiding van
de terugreistijd en de measured-vs-national snelheidsbron. IJkstap vóór er mail
uitgaat. Draai 004 + het geocode-backfill + 005 (concept) + 006 eerst.
Concept-diensten ('draft') worden nooit meegenomen.

```powershell
$env:SUPABASE_SERVICE_ROLE_KEY="<service-role-key>"
npm run calibrate                       # dry run, alleen rapport
npm run calibrate -- --write            # schrijft naar shift_time_reports
npm run calibrate -- --from=2025-01-01 --to=2025-03-31
```

Het rekenmodel is bewust puur (geen Supabase); alle marges/drempels/factoren
staan in `src/timesheet/constants.ts` en zijn bij te stellen zonder de logica te
raken.

## SMS-herinnering (fase 4)

Eén SMS per dienst, 24 uur vóór aanvang, alleen voor **bevestigde** diensten
(`status = 'planned'`) met een toegewezen koerier die een nummer heeft. Wijzigt
de planning daarna, dan gaat er géén correctiebericht uit — dat is telefonisch
afgestemd.

### Waar de nummers staan

In `courier_contacts` (migratie 011), **niet** op `user_profiles`. Die tabel is
van de bezorg-app: een gebruiker mag daar zijn eigen rij lezen en
`authService.login()` haalt hem op met `select('*')`, waardoor een nummer in de
bezorg-app-client zou belanden. `courier_contacts` heeft alleen
`is_privileged()`-policies: een koerier kan geen enkel nummer lezen of
schrijven, ook zijn eigen niet.

Invoeren gaat via **Nummers** in de kop van de planner. Het scherm normaliseert
naar E.164 (`06…` → `+316…`), waarschuwt bij een nummer dat geen NL-mobiel lijkt,
en meldt bovenaan welke koeriers een bevestigde dienst in de komende twee weken
hebben maar geen nummer.

### Hoe de job werkt

`supabase/functions/send-shift-reminders/` draait elk uur en doet per dienst:

1. `sms_due_shifts()` — alles wat binnen 24 uur begint, nog in de toekomst ligt
   en nog geen logrij heeft. Een **inhaal-sweep**, geen strak venster.
2. `sms_claim_shift()` — logrij wegschrijven vóór het versturen. `shift_id` is de
   primaire sleutel van `shift_sms_log`; dat is de hele garantie van "één bericht
   per dienst", ook bij een herstart of twee gelijktijdige runs.
3. Brevo aanroepen.
4. `sms_record_result()` — `sent` of `failed` terugschrijven.

Slaat een run over, dan pakt de volgende alles op wat nog niet begonnen is.
Crasht het proces tussen 2 en 3, dan blijft de rij op `sending` staan en gaat er
géén bericht meer uit voor die dienst (fail-closed). De status staat per dienst
in het weekoverzicht, zodat je een stilgevallen job ziet tijdens je gewone
planwerk.

### Eenmalig instellen

1. **Brevo** — registreer de afzender-ID `Greenspeed` voor Nederland
   (verplicht voor accounts van ná 13 maart 2026, en er zit doorlooptijd in) en
   koop SMS-credits. Twee dingen die anders misgaan:

   * **De juiste sleutel.** Neem een API-sleutel van het type `xkeysib-…` uit
     **SMTP & API → API keys**. De sleutel uit het SMTP-tabblad (`xsmtpsib-…`)
     werkt niet voor deze API en geeft `Brevo 401: Key not found`.
   * **IP-blokkering uit.** Staat er onder
     [app.brevo.com/security/authorised_ips](https://app.brevo.com/security/authorised_ips)
     een IP-lijst aan, zet die dan uit. Een Edge Function heeft een wisselend
     uitgaand IP en valt er dus altijd buiten; de foutmelding is
     `unrecognised IP address`.
2. **CLI koppelen** (eenmalig, in deze projectmap):
   ```powershell
   npx supabase init      # maakt alleen supabase/config.toml aan; migraties blijven
   npx supabase link --project-ref <project-ref>
   ```
3. **Secrets zetten:**
   ```powershell
   npx supabase secrets set BREVO_API_KEY=xkeysib-<sleutel> SMS_SENDER=Greenspeed CRON_SECRET=<willekeurige string>
   ```
   `SUPABASE_URL` en `SUPABASE_SERVICE_ROLE_KEY` zet Supabase zelf al klaar.
4. **Deployen:**
   ```powershell
   npx supabase functions deploy send-shift-reminders
   ```
5. **Proefdraaien vóór de cron** — dit stuurt niets en claimt niets, maar laat
   precies zien wie een bericht zou krijgen:
   ```powershell
   curl -X POST "https://<project-ref>.supabase.co/functions/v1/send-shift-reminders?dry_run=1" `
     -H "Authorization: Bearer <service-role-key>" -H "x-cron-secret: <CRON_SECRET>"
   ```
   Let op: bij de eerste échte run krijgt **elke** al bevestigde dienst binnen 24
   uur meteen een bericht. Kijk in de dry run of dat aantal klopt.
6. **Cron aanzetten** — extensies `pg_cron` en `pg_net` aan (Database →
   Extensions), daarna in de SQL Editor:
   ```sql
   SELECT cron.schedule('sms-dienstherinnering', '5 * * * *', $$
     SELECT net.http_post(
       url     := 'https://<project-ref>.supabase.co/functions/v1/send-shift-reminders',
       headers := jsonb_build_object(
                    'Authorization', 'Bearer <service-role-key>',
                    'x-cron-secret', '<CRON_SECRET>',
                    'Content-Type',  'application/json'),
       body    := '{}'::jsonb
     );
   $$);
   ```
   Elk uur op :05. Draait in UTC, maar dat maakt niet uit: de 24-uursgrens wordt
   in `sms_due_shifts` in `Europe/Amsterdam` berekend, dus de zomertijd verschuift
   hem niet.

   Controleren: `SELECT * FROM cron.job;` en
   `SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;`

### Omgevingsvariabelen

| Variabele | Standaard | Waarvoor |
|---|---|---|
| `BREVO_API_KEY` | — | verplicht, behalve in dry run; type `xkeysib-…` |
| `SMS_SENDER` | `Greenspeed` | alfanumerieke afzender (3–11 tekens) |
| `SMS_WINDOW_HOURS` | `24` | hoe ver vooruit de sweep kijkt |
| `SMS_MAX_PER_RUN` | `50` | veiligheidsrem; overschot komt de volgende run |
| `SMS_DRY_RUN` | — | `1` = niets claimen, niets versturen |
| `CRON_SECRET` | — | indien gezet, verplicht als header `x-cron-secret` |

### Handmatig herkansen

Een `failed`-rij blijft staan en blokkeert verdere pogingen — bewust, want een
time-out kan niet onderscheiden of het bericht wél of niet verstuurd is.
Opnieuw proberen doe je door de logrij te verwijderen; de eerstvolgende run pakt
de dienst dan weer op (mits hij nog in de toekomst ligt):

```sql
DELETE FROM public.shift_sms_log WHERE shift_id = '<uuid>';
```

### Randgevallen om te kennen

* **Verwijderde en opnieuw aangemaakte dienst** telt als een nieuwe dienst en
  krijgt dus wél een eigen bericht (nieuw `shift_id`).
* **Koerier gewisseld ná het bericht**: de nieuwe koerier krijgt niets. Dat is de
  afspraak — telefonisch afstemmen.
* **Concept dat laat bevestigd wordt** valt vanaf dat moment in de sweep; staat
  de dienst dan nog in de toekomst, dan gaat het bericht alsnog uit.
* **Berichttekst** staat op één plek, in `buildMessage()`:

  > Reminder: je bent ingepland op do 30-07 19:12 bij Lamberts Apotheek. Vragen
  > of verhinderd? Bel de planning. Je kunt niet antwoorden op deze SMS

  Accentloos houden — `toGsm7()` haalt accenten er automatisch uit, want één
  accent zet het hele bericht om naar Unicode en dan is een segment nog 70
  tekens in plaats van 160. Er wordt **niet** afgekapt: twee segmenten mag, dat
  kost een tweede credit.
* **Meerdere apotheken** worden allemaal genoemd, als zin: "bij A en B",
  "bij A, B en C". Met één naam is het bericht ~143 tekens, dus er is zo'n 17
  tekens speling binnen het eerste segment; vanaf twee namen loopt het richting
  de tweede. De dry run toont per bericht `chars`, `segments` en `encoding`, en
  in de samenvatting `segments_total` — het aantal credits dat die run kost.
