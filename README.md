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

`014_invitations_rls_test.sql` doet zich voor als een gewone gebruiker met
`SET LOCAL ROLE authenticated`. Zonder die rolwissel draai je als `postgres` en
die omzeilt RLS volledig — de test slaagt dan altijd en bewijst niets.

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
