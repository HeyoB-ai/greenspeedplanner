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
| `018_shift_declarations.sql` | nadeclaratie: standplaats, `courier_distances`, `reimbursement_rates`, `shift_declarations` + de rekenregel `declaration_compute()` |
| `019_declaration_mail.sql` | nadeclaratie: `declaration_sweep()`, de berichtsoort `shift_followup`, de token-functies en de plannerkant |
| `020_declaration_branch.sql` | de standplaatstak geldt alleen als álle apotheken van de dienst de standplaats zijn; een ontbrekende afstand levert onbekend op in plaats van een te laag bedrag |
| `021_declaration_timeliness.sql` | `expected_within_hours` (standaard 48) en de afgeleide tijdigheid in `declaration_overview()`; de invullink blijft onveranderd 30 dagen geldig |
| `022_declaration_submit_reasons.sql` | `declaration_submit()` zegt wélke reden er is (verlopen / in behandeling / goedgekeurd); een onbekend token houdt de nietszeggende melding |
| `023_declaration_by_token_review.sql` | `declaration_by_token()` geeft ook `approved` en `disputed` terug, met `review_note`; de invulpagina toont die als leesweergave |
| `024_pharmacy_city.sql` | `pharmacies.city` leesbaar en bewerkbaar maken via `set_pharmacy_city()` — de kolom zelf bestond al in het schema van de bezorg-app |
| `025_pharmacy_invoicing.sql` | facturatie: `shift_pharmacies.budgeted_minutes`, `pharmacy_rates`, spoedbedrag op `shifts`, en `invoice_lines()` |
| `026_invoice_lines_fixes.sql` | `invoice_lines()`: reden-opbouw (`::TEXT`, zie hieronder), en een regel zonder duur krijgt geen bedrag in plaats van nul |
| `027_declaration_compute_cast.sql` | dezelfde `::TEXT` op de drie vaste zinnen in `declaration_compute()`; alleen een cast, geen gedragswijziging |
| `028_declaration_expenses.sql` | onkosten bij een declaratie (`declaration_expenses`), doorbelast in `invoice_lines()`; `declaration_by_token()` en `declaration_overview()` krijgen de posten erbij |
| `029_employees.sql` | personeelsadministratie los van `auth.users`: `employees`, `employee_active_on()`, import, en de overname van de bestaande koeriers |
| `030_rate_per_transport.sql` | vier uurtarieven per apotheek (fiets, auto, instelling, overig); `invoice_lines()` kiest op diensttype en vervoermiddel |
| `031_extra_work.sql` | meerwerk: `extra_work`, de vrijgave door de planner, de goedkeuringslus met de apotheek, en `pharmacies.billing_email` |
| `032_chain_split.sql` | factuursplitsing keten/filiaal, per keten in te schakelen: gebudgetteerde uren naar het centrale adres, meerwerk naar het filiaal |
| `033_planner_attention.sql` | `planner_attention()`: telt wat op de planner wacht, voor de badge op het menu Financieel |

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
| `018_shift_declarations_test.sql` | de vier takken van de reiskostenregel plus de randen: drempel vervalt bij eigen auto en bij een andere apotheek, nul is niet onbekend, tarief per dienstdatum, km's geweigerd bij een fietsdienst |
| `019_declaration_mail_test.sql` | sweep (idempotent, venster, vloer, te oude diensten), token uitgeven en gebruiken, indienen, leeftijdscontrole, en dat de link stopt na beoordeling |
| `020_declaration_branch_test.sql` | de tak-keuze bij meerdere apotheken: één andere apotheek is genoeg voor `other_pharmacy` met de volle afstand, een ontbrekende afstand geeft onbekend mét naam, en bij eigen auto raakt dat alleen de referentie |
| `021_declaration_timeliness_test.sql` | binnen/buiten de termijn ingediend, een openstaande rij zonder oordeel, de termijn is instelbaar (72 uur maakt dezelfde rij op tijd), en de link werkt na te laat indienen gewoon door |
| `022_declaration_submit_reasons_test.sql` | de vier uitkomsten van indienen (28000 / 45001 / 45002 / 45003), dat een onbekend token exact dezelfde tekst houdt, en dat gewoon indienen nog werkt |
| `023_declaration_by_token_review_test.sql` | beoordeelde declaraties komen terug mét status en reden, een verlopen of onbekend token nog steeds niet, en opslaan blijft geweigerd |
| `024_pharmacy_city_test.sql` | plaats zetten (getrimd), leeg opslaan wist het veld, onbekende apotheek geeft een fout, en een koerier mag het niet |
| `026_invoice_lines_fixes_test.sql` | dat een vaste zin als reden terugkomt, dat een dienst zonder duur zichtbaar blijft zonder bedrag, en dat een regel zonder totaal geen losse bedragen houdt |
| `027_declaration_compute_cast_test.sql` | de drie takken met een vaste zin (geen standplaats, onbekende afstand, dienst zonder apotheek) geven een reden terug, met ongewijzigde uitkomsten |
| `028_declaration_expenses_test.sql` | posten vastleggen (lege regels vallen weg), terugzien op de invulpagina en in het plannerscherm, naar rato doorbelast, en dicht na goedkeuring |
| `029_employees_test.sql` | medewerker zonder inlogaccount, uit dienst als datum (en actief op een oude datum), import die bijwerkt in plaats van dupliceert, geen personeelsnummer, en dat een losgemaakt profiel de medewerker laat staan |
| `030_rate_per_transport_test.sql` | het juiste tarief per diensttype en vervoermiddel, spoed ongewijzigd, een onbekend vervoermiddel zonder bedrag maar mét reden, en een starttarief van 0 als geldige waarde |
| `031_extra_work_test.sql` | drempel, verdeling over twee apotheken, vrijgave (met en zonder adres), token en antwoord, en de drie factuuruitkomsten — plus dat de declaratie van de koerier nergens door verandert |
| `032_chain_split_test.sql` | splitsing uit én aan, het gereserveerde blok bij korter werken, meerwerk/reiskosten/onkosten/spoed naar het filiaal, en dat keten + filiaal optelt tot het regeltotaal |
| `033_planner_attention_test.sql` | wat wel en niet meetelt (ingediend wel, openstaand niet; nieuw wel, vrijgegeven niet), het totaal, en dat een koerier nullen krijgt |
| `025_pharmacy_invoicing_test.sql` | de elf takken van `invoice_lines()`: één en twee apotheken (uitloop én korter), starttarief niet verdeeld, spoed, ontbrekende declaratie, ontbrekend tarief, ontbrekende verhouding, reiskosten naar rato, afwijkingssignaal, en dat concepten niet meetellen |
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

Per koerier: **eerst het adres bepalen, dan claimen.** Is er geen adres of houdt
de poort het tegen, dan wordt er niet geclaimd en blijven de berichten op
`pending` staan — ze gaan gewoon mee zodra het adres er is of de beperking eraf
gaat. Zou je eerst claimen, dan zou zo'n bundel als mislukt eindigen en nooit
meer uitgaan.

**De poort is fail-closed.** Bij de SMS zat de bescherming in de data: alleen
ingevoerde nummers konden bereikt worden. Bij mail heeft élke koerier al een
adres in `auth.users`, dus configuratie is het enige vangnet — en een vergeten of
verkeerd getypt secret mag niet betekenen dat alles uitgaat.

| `MAIL_ALLOWLIST` | `MAIL_LIVE` | Wat er gebeurt |
|---|---|---|
| leeg | uit | **niets** gaat uit; alles blijft wachten |
| gevuld | uit | alleen naar de adressen op de lijst |
| gevuld | `1` | alleen naar de adressen op de lijst — de allowlist wint, mét waarschuwing in de logs |
| leeg | `1` | naar alle koeriers |

Live gaan is dus twee bewuste handelingen: `MAIL_LIVE=1` zetten én de allowlist
wissen. "Leeg" betekent nooit vanzelf "naar iedereen".

De dry run negeert de poort niet maar toont hem: per koerier staat er
`would_send` en `blocked_by` bij, zodat je de poort kunt controleren vóór je hem
opent.

| Variabele | Standaard | Waarvoor |
|---|---|---|
| `BREVO_API_KEY` | — | verplicht, behalve in dry run; type `xkeysib-…` |
| `MAIL_FROM` | — | afzenderadres, nu `planning@greenspeedkoeriers.nl` (**mét** s) |
| `MAIL_FROM_NAME` | `Greenspeed Planning` | weergavenaam |
| `MAIL_REPLY_TO` | — | `info@greenspeedkoerier.nl` (**zonder** s). Hoeft niet geverifieerd te zijn in Brevo — dat geldt alleen voor de afzender |
| `MAIL_ALLOWLIST` | — | komma-gescheiden adressen; gevuld = **alleen daarheen** |
| `MAIL_LIVE` | — | `1` = naar alle koeriers. Zonder allowlist én zonder deze vlag gaat er **niets** uit |
| `MAIL_MAX_PER_RUN` | `25` | koeriers per run; overschot komt de volgende run |
| `MAIL_DRY_RUN` | — | `1` = niets claimen, niets versturen |
| `CRON_SECRET` | — | indien gezet, verplicht als header `x-cron-secret` |

Uitrollen:

```powershell
npx supabase secrets set MAIL_FROM=planning@greenspeedkoeriers.nl `
  MAIL_FROM_NAME="Greenspeed Planning" `
  MAIL_REPLY_TO=info@greenspeedkoerier.nl `
  MAIL_ALLOWLIST="jouw@eigenadres.nl"
npx supabase functions deploy send-shift-mail
```

> ⚠️ **Vóór je live gaat: afzender en reply-to op hetzelfde domein zetten.**
> Nu vertrekt de mail van `planning@greenspeedkoerier**s**.nl` (testdomein, mét s)
> terwijl antwoorden naar `info@greenspeedkoerier.nl` gaan (echte domein, zónder
> s). Twee domeinen die één letter schelen, in één bericht — dat is voor een
> koerier niet te onderscheiden van een phishingpoging, en spamfilters kijken er
> ook naar. Zolang `MAIL_ALLOWLIST` alleen jouw eigen adres bevat ziet niemand
> anders het. Zodra `greenspeedkoerier.nl` in Brevo geverifieerd is, zet je
> `MAIL_FROM` daarheen om en klopt het weer.

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

### De zeven berichtsoorten

Alle tekst staat op één plek: `renderBlock()` en `subjectFor()` in de functie.
Accentloos, en per blok staat er wat de koerier moet doen of weten. Een bundel
krijgt één aanhef en één afsluiting, met een blok per feit in de volgorde waarin
ze ontstonden.

Boven de inhoud staat een **peildatum** (`Stand op 30-07-2026:`), en regels noemen
alleen wanneer iets ingaat, nooit wanneer het ophoudt. Reden: de vingerafdruk
bevat bewust geen datums, dus een later op een oude tijd bevestigde dienst levert
geen nieuwe mail op. Zonder peildatum zou zo'n bericht onwaar worden; mét is het
hooguit onvolledig. Zie punt 10 van het ontwerp.

| Soort | Onderwerp | Kern van het blok |
|---|---|---|
| `schedule_confirmed` | Je vaste dienst staat vast | `Je staat vast ingepland:` + een regel per variant met ingangsdatum |
| `schedule_changed` | Je vaste dienst is gewijzigd | `Dit staat er nu:` + alle varianten, elk als `vanaf <datum>: elke <dag> <tijd> bij <apotheek>` |
| `shift_confirmed` | Je bent ingepland op \<dag\> \<datum\> | `Je bent ingepland op donderdag 30-07-2026, 19:12-21:00 bij X, met de auto.` |
| `shift_changed` | Je dienst van \<dag\> \<datum\> is gewijzigd | `Dit staat er nu: …` |
| `shift_cancelled` | Je dienst van … vervalt / gaat naar een andere koerier | `Deze dienst vervalt: … Je hoeft niet te komen.` |
| `schedule_cancelled` | Je vaste dienst vervalt | nog niet in gebruik; staat er zodat een onbekend feit geen lege mail oplevert |
| `shift_followup` | Hoe lang duurde je dienst van \<dag\> \<datum\>? | de invullink van de nadeclaratie (fase 6); bij een eigen auto ook de vraag om de totaal gereden kilometers |

## Medewerkers (fase 8) — migratie nog niet gedraaid

Het ontwerp met alle afwegingen staat in
[`docs/FASE8_PERSONEEL_ONTWERP.md`](docs/FASE8_PERSONEEL_ONTWERP.md).

`employees` is de personeelsadministratie, **los van `auth.users`**. Reden:
`user_profiles.id` heeft een foreign key naar `auth.users(id)` met
`ON DELETE CASCADE`. Daardoor kan er geen medewerker bestaan zonder inlogaccount,
en sleept een verwijderd account het profiel mee — met de urenhistorie eraan, die
zeven jaar bewaard moet blijven.

`employees.user_profile_id` staat daarom op **`ON DELETE SET NULL`**: verdwijnt
het account, dan verliest de medewerker zijn inlog, niet zijn historie.

**Uit dienst is een datum, geen vinkje.** `employed_until` in het verleden =
verdwenen uit de keuzelijsten, maar een urenexport over maart bevat hem gewoon.
Die logica staat op één plek: `employee_active_on(employee_id, date)` en de view
`employees_active`.

### Importeren

*Medewerkers → CSV importeren.* Een kopregel met onder meer `Personeelsnummer`,
`Voornaam`, `Achternaam`, `E-mail`, `Telefoon`, `Dienstverband`, `Uurloon`,
`In dienst` en `Uit dienst`; komma's en puntkomma's mogen allebei. Er wordt
gekoppeld op personeelsnummer en anders op naam, dus **dezelfde lijst opnieuw
draaien werkt bij** in plaats van te dupliceren. Een lege kolom overschrijft
niets. Zonder personeelsnummer wordt iemand gewoon aangemaakt, met een markering
bovenaan de lijst.

Na afloop toont het scherm per rij wat ermee gebeurd is — "69 verwerkt" zegt
niets als er drie zijn overgeslagen.

### ⚠ Twee besluiten staan open

1. **Waar wijst een dienst naar?** `shifts.courier_id` verwijst naar
   `user_profiles`, dus je kunt nog géén dienst inplannen voor iemand zonder
   account. Drie varianten met hun gevolgen staan in punt 4 van het ontwerp, met
   een aanbeveling. `shifts` is in deze migratie **niet** aangeraakt.
2. **De regiolaag.** Conclusie: een eigen laag, niet `groups` — die gaat over
   ketens. Punt 3 van het ontwerp. Ook niet gebouwd.

## De menubalk

Tien knoppen naast elkaar was er één te veel; de balk liep vol en alles woog
even zwaar. De indeling nu:

| In de balk | Waarom los |
|---|---|
| **Rooster bijwerken** | hoort bij het plannen, gebruik je terwijl je in het overzicht zit |
| **Vernieuwen** | idem |

| Menu | Bevat | Waarom bij elkaar |
|---|---|---|
| **Beheer** | Medewerkers, Apotheken, Afstanden, Nummers | stamgegevens; je raakt ze zelden aan en dan meestal doelgericht |
| **Financieel** | Declaraties, Meerwerk, Facturatie | de maandelijkse ronde, in die volgorde: eerst wat de koerier opgaf, dan wat de apotheek moet goedkeuren, dan de factuur |

Rechts staat het account, met **Uitloggen** eronder.

### De telbadge op Financieel

Wegstoppen achter een klik heeft een prijs: een ingediende declaratie of een
nieuwe meerwerkmelding is dan niet meer te zien zonder te gaan kijken. Daarom
staat er een teller op **Financieel**, en dezelfde getallen staan bij de
onderdelen zelf zodra je uitklapt.

Geteld wordt **alleen wat op de planner ligt te wachten**:

| Telt mee | Telt niet mee | Waarom niet |
|---|---|---|
| declaratie `submitted` | declaratie `open` | daar wachten we op de koerier |
| meerwerk `new` | meerwerk `released` | ligt bij de apotheek, 48 uur |
| | meerwerk `expired` | zonder reactie gewoon factureerbaar |
| | meerwerk `disputed` | afgehandeld door de klant; hoort niet in een werkvoorraad |

Zou `open` meetellen, dan is de badge geen werkvoorraad meer maar een getal dat
elke week oploopt en dat niemand nog leest. Betwist meerwerk is een grensgeval —
het vraagt wél iets — maar het staat in het meerwerkscherm bovenaan en niet in
deze teller.

De telling zit in `planner_attention()` (migratie 033) en niet in de frontend:
twee volledige overzichten ophalen om er twee getallen uit te tellen zou bij elke
verversing alle declaraties over de lijn trekken. De functie is `SECURITY
DEFINER` en leest twee dichte tabellen, dus staat `is_privileged()` in beide
takken — een koerier krijgt nullen. Mislukt de aanroep, dan verdwijnt de badge in
plaats van het scherm te breken; zolang migratie 033 nog niet gedraaid is werkt
de balk dus gewoon, zonder teller.

De teller ververst mee met **Vernieuwen** en met elke mutatie, en de schermen
Declaraties en Meerwerk werken hem bij zodra je ze sluit.

### Toetsenbord

| Toets | Doet |
|---|---|
| Tab | loopt door de balk en, met het menu open, door de items |
| Enter | opent het menu en kiest het item |
| Escape | sluit het menu en zet de focus terug op de menuknop |
| ↑ ↓ | lopen door de items, rondlopend |

De items zijn gewone knoppen en blijven met Tab bereikbaar; er is bewust geen
roving tabindex, want die zou Tab uit het menu gooien. Klikken buiten het menu
sluit het, en focus die het menu verlaat ook.

## Het weekoverzicht

Twee weergaven, te wisselen met de schakelaar linksboven:

* **Apotheken** (standaard) — apotheken op de y-as, dagen op de x-as. Hier plan je:
  een lege cel is een knop om een dienst toe te voegen. Dit is de weergave die
  gebruikers uit L1nda kennen, dus die blijft de standaard.
* **Koeriers** — koeriers op de y-as, met per cel de diensten van die dag
  (begintijd, apotheek, vervoermiddel). **Alleen lezen**: er zit geen klikbare cel
  in. Bovenaan staat een rij `Open (niet toegewezen)`, want anders zou juist de
  dienst die aandacht nodig heeft hier onzichtbaar zijn. Alleen koeriers met
  minstens één dienst in de week krijgen een rij.

Beide weergaven volgen dezelfde filters. Het apotheekfilter filtert in de
apotheekweergave rijen weg en in de koeriersweergave diensten.

### Groeperen op plaats

Met **Groepeer op plaats** komen de apotheken onder inklapbare plaatskoppen te
staan, alfabetisch, met apotheken zonder plaats onderaan in **Overig**. De
schakelaar staat standaard uit: bij een handvol apotheken is groeperen meer
omhaal dan overzicht.

De plaats komt uit `pharmacies.city`. Die kolom bestond al in het schema van de
bezorg-app maar was nergens te vullen; sinds migratie 024 doe je dat in
**Apotheken** in de kop van de app. Hij wordt **niet** uit het adres afgeleid: de
schrijfwijzen lopen uiteen, en dan staan "Hilversum" en "1213 BE Hilversum" als
twee plaatsen in het overzicht. Een foute groepering is erger dan geen
groepering, want die eerste ziet niemand. Het invoerveld biedt de al gebruikte
plaatsen als suggestie aan, zodat er niet per ongeluk twee schrijfwijzen ontstaan.

## Meerwerk (fase 9) — migraties nog niet gedraaid

Loopt een dienst uit, dan mag de apotheek daar eerst iets van vinden voordat het
doorbelast wordt. Het ontwerp staat in de kop van
[`supabase/migrations/031_extra_work.sql`](supabase/migrations/031_extra_work.sql).

```
dienst loopt af → koerier vult in → uitloop >= drempel → melding klaar
    → PLANNER GEEFT VRIJ → mail naar de apotheek → 48 uur → akkoord of niet
```

**De planner zit er bewust tussen.** De toelichting van de koerier gaat mee naar
de klant, en "moest wachten want de assistente was er niet" is niet iets wat je
ongelezen doorstuurt. De sweep maakt daarom wél de melding maar géén mail; er is
geen pad waarlangs er iets naar een apotheek vertrekt zonder dat iemand op
*Vrijgeven* heeft geklikt. In het scherm *Meerwerk* staat de tekst die de klant
te lezen krijgt bewerkbaar klaar, voorgevuld met wat de koerier schreef.

| Uitkomst | Op de factuur |
|---|---|
| `approved` | de volle uren |
| `expired` (geen reactie binnen 48 uur) | ook de volle uren, maar **apart herkenbaar** |
| `disputed` | alleen de geplande uren; de uitloop blijft eraf tot er telefonisch iets is afgesproken |
| nog niet vrijgegeven / nog geen antwoord | idem: alleen de geplande uren |

Dat laatste is de conservatieve kant: te weinig factureren corrigeer je met een
telefoontje, te veel kost vertrouwen. `billed_minutes` blijft wél tonen wat er
werkelijk gewerkt is.

> **De koerier wordt in álle gevallen gewoon uitbetaald.** Een geschil met de
> klant is een geschil tussen Greenspeed en de apotheek; dat mag niet doorwerken
> in het loon van iemand die de uren heeft gemaakt. Er is daarom geen enkele
> verwijzing vanuit de nadeclaratieketen naar de meerwerkstatus, en
> `declaration_compute()` is niet aangeraakt.

Drempel en termijn staan in `invoice_settings`, niet in code:

```sql
UPDATE public.invoice_settings
   SET extra_work_threshold_minutes = 15, extra_work_respond_hours = 48;
```

### Wat je eerst moet vullen

**Een e-mailadres per apotheek** (*Apotheken*). Zonder adres kan een melding niet
vrijgegeven worden; het scherm *Meerwerk* zegt dan welke apotheken het betreft.

### Uitrollen

```powershell
npx supabase secrets set EXTRA_WORK_URL=https://<app>/meerwerk
npx supabase functions deploy extra-work
npx supabase functions deploy send-shift-mail    # tweede ronde voor apotheekpost
```

De verzender heeft er een tweede ronde bij gekregen: post zonder `courier_id`
gaat naar het adres in `recipient_override`. Voor de keten van fase 5 verandert
er niets — `mail_pending_couriers()` joint op `user_profiles` en ziet die rijen
niet eens.

De cron voor `extra_work_sweep()`:

```sql
SELECT cron.schedule('extra-work-sweep', '30 * * * *', $$
  SELECT public.extra_work_sweep();
$$);
```

> ⚠ De `Authorization`-header luidt `'Bearer ' || <sleutel>` — het woord
> `Bearer`, een spatie, dán de sleutel. Controleren doe je in
> `net._http_response`, niet in `cron.job_run_details`.

### Factuursplitsing keten / filiaal

Per keten in te schakelen (*Apotheken → Ketens*), **standaard uit**. Staat hij uit,
dan gaat alles naar het filiaal en verandert er geen cent — dat is de situatie
voor iedereen tot iemand hem aanzet.

Staat hij aan:

| Naar de keten | Naar het filiaal |
|---|---|
| de gebudgetteerde uren | goedgekeurd of verlopen meerwerk |
| het starttarief | reiskosten en onkosten |
| | spoed (telefonisch met het filiaal afgesproken) |

De regel in één zin: **het geplande pakket naar de keten, alles wat daarvan
afwijkt naar het filiaal.**

> ⚠ **Binnen de splitsing is het budget een gereserveerd blok.** De keten betaalt
> de volle gebudgetteerde uren, ook als de koerier eerder klaar was. Dat is een
> **variant, geen nieuwe hoofdregel**: zonder splitsing geldt onverkort wat er
> stond — werkelijke uren, in beide richtingen, geen ondergrens en geen plafond.
> Geval 3 van `025_pharmacy_invoicing_test.sql` bewaakt die oude regel, geval 9
> van `032_chain_split_test.sql` bewaakt dat de nieuwe niet stiekem overal gaat
> gelden.
>
> Gevolg om te kennen: bij een gesplitste keten kan een regeltotaal hóger
> uitvallen dan zonder splitsing, namelijk als er korter gewerkt is.
> `billed_minutes` blijft tonen wat er werkelijk gewerkt is.

Aanzetten kan pas als er een centraal factuuradres staat — anders levert het
facturen op die nergens heen kunnen. In het factuurscherm verschijnt dan een
schakelaar **Filiaal / Keten**; de laatste kolom toont het deel voor de gekozen
ontvanger, met het regeltotaal eronder.

De goedkeuringslus verandert niet: het meerwerk hoort bij het filiaal dat het
veroorzaakte, en daar ging de mail al heen. Wel staat er sinds de splitsing een
zin bij dat déze tijd op de eigen factuur van het filiaal komt en niet op die van
de keten — zonder die zin denkt de lezer aan de factuur die hij van zijn keten
kent.

## Facturatie (fase 7) — migratie nog niet gedraaid

Het ontwerp met alle redenen staat in
[`docs/FASE7_FACTURATIE_ONTWERP.md`](docs/FASE7_FACTURATIE_ONTWERP.md).

Uit de planning en de nadeclaraties factuurregels afleiden per apotheek per
periode. **Er wordt niets gegenereerd en niets verstuurd** — dit is een model en
een overzicht.

```
Uren        naar rato van de geplande minuten per apotheek, in beide richtingen
Starttarief NIET verdeeld: elke apotheek een volledige, tegen haar eigen tarief
Reiskosten  naar rato, zelfde verhouding als de uren
Spoed       alleen het telefonisch afgesproken bedrag; geen uren, geen starttarief
```

> ⚠ De opdracht spreekt van `shift_type = 'spoed'`; die waarde bestaat niet. Het
> type heet **`urgent`** (migratie 001), "Spoed" is het label in de interface.

### Wat je moet invullen voordat het klopt

1. **Tarieven per apotheek** — *Apotheken → Tarieven*. Sinds migratie 030 zijn
   dat er vier: **fiets**, **auto**, **instelling** en **overig transport**
   (klussen). Welk tarief geldt hangt af van het diensttype, en bij een reguliere
   dienst van het vervoermiddel; spoed rekent alleen het afgesproken bedrag.
   Een leeg tariefveld betekent *geen tarief voor dat soort werk* — een dienst van
   die soort levert dan een onvolledige factuurregel op in plaats van een nul.
   Het **starttarief** staat daar los van en wordt niet verdeeld; bij
   BENU-filialen staat er 0 in, en dat is een waarde en geen uitzondering.
   Er worden er bewust geen voorgevuld: er is geen landelijk getal om op terug te
   vallen, en een verzonnen tarief merk je pas als de factuur weg is.
2. **Geplande minuten per apotheek** — in *Dienst toevoegen* / *Dienst bewerken*,
   per aangevinkte apotheek. Alleen nodig bij gedeelde diensten; ontbreekt het,
   dan wordt gelijk verdeeld en de regel gemarkeerd.

### ⚠ `text[] || 'tekst'` — een valkuil die nog ergens anders zit

`invoice_lines()` liep stuk op **"malformed array literal"** bij het samenstellen
van de reden. Niet door een verkeerde toewijzing: élke regel gebruikte al `||`.
Het zit in de operatorkeuze. Voor `text[] || <letterlijke tekst>` heeft Postgres
twee kandidaten —

```
anyarray || anyelement    -- array met een element erbij
anyarray || anyarray      -- twee arrays aan elkaar
```

— en een letterlijke `'tekst'` heeft type `unknown`, dus die past op allebei.
Kiest Postgres de tweede, dan leest hij de zin als array-literaal (`{…}`) en
klapt hij om op de uitvoering, niet bij het aanmaken van de functie. Regels met
`format(…)` hebben er geen last van: die geven een getypeerde `text` terug.

De oplossing is één cast: `v_reasons := v_reasons || 'reden'::TEXT`.

> Dezelfde constructie stond in `declaration_compute()` (migratie 020, regels
> 102, 145 en 161). **Migratie 027 zet daar dezelfde cast**, en verder niets: de
> body is die van 020 met op drie regels een `::TEXT` erbij. Het ging om de
> takken die zich nog niet hadden voorgedaan — een koerier zonder standplaats,
> een onbekende afstand, of een dienst zonder apotheek — en dat is meteen de
> reden dat het daar niet eerder opviel.

### Markeringen

Amber betekent: er ontbrak iets, of er is iets opvallends. De regel wordt wél
berekend met wat er is — een factuur wordt hier niet door opgehouden. Een regel
zonder totaal (geen tarief, of geen duur) houdt **geen enkel** los bedrag en telt
apart, zodat de kolommen altijd optellen tot het eindtotaal en een subtotaal nooit
stilzwijgend te hoog of te laag is.

Is er geen werkelijke duur én geen geplande eindtijd, dan valt er niets te
factureren. Die regel verschijnt tóch in het overzicht — zonder bedrag en met de
markering — want stilzwijgend wegvallen betekent dat de planner de dienst
helemaal mist.

De afwijkingsgrens (standaard 25%) is instelbaar:

```sql
UPDATE public.invoice_settings SET deviation_pct = 40;
```

Concepten (`status = 'draft'`) tellen niet mee: die zijn niet bevestigd en dus
geen opdracht.

## Nadeclaratie (fase 6) — nog niet aangezet

Het ontwerp met alle redenen staat in
[`docs/FASE6_NADECLARATIE_ONTWERP.md`](docs/FASE6_NADECLARATIE_ONTWERP.md).

Na afloop van een dienst krijgt de koerier een mail met een link. Achter die link
vult hij in hoe lang de dienst werkelijk duurde en of hij reiskosten declareert.
De planner ziet daarna per dienst het opgegeven naast het berekende, met het
verschil erbij (*Declaraties* in de kop van de app).

De regel:

```
eigen auto?
+- ja  -> opgegeven km's x autotarief          (own_car)
+- nee -> andere apotheek dan de standplaats?
          +- ja  -> volledige afstand vergoed   (other_pharmacy)
          +- nee -> afstand - drempel, min. 0   (above_threshold / none)
```

Bij eigen auto en bij een andere apotheek vervalt de drempel volledig. Dat is
tegenintuitief en bewust zo bevestigd; zie punt 1 van het ontwerp.

> ⚠ **Zet de cron voor `declaration_sweep()` nog NIET aan** voordat stap 1 t/m 6
> hieronder gedaan zijn. `declaration_settings.active_from` beschermt tegen mail
> over de hele historie, maar alleen als hij klopt.

### Het woonadres wordt niet opgeslagen

Het adres gaat één keer naar de Edge Function `courier-distances`, die het
geocodeert, de route-afstanden berekent naar álle apotheken waar de koerier aan
gekoppeld is, en **alleen die afstanden** wegschrijft in `courier_distances`.
Geen bewaartermijn op adresgegevens, en een lek levert niemands woonplaats op.
Het invoerveld in *Afstanden* wordt na een geslaagde berekening leeggemaakt.

> ⚠ **Openstaande blokkade:** apotheken zonder `addressLat`/`addressLng` kunnen
> niet meegerekend worden. Het scherm benoemt ze per koerier en biedt handmatige
> invoer (`source = 'manual'`). Structureel oplossen doe je met
> `scripts/backfill-pharmacy-coords.mjs`, en dat vergt eerst adresgegevens op de
> apotheek zelf.

### Onkosten

Naast de kilometervergoeding kan een koerier losse posten opgeven: parkeren, een
veerpont, een OV-kaartje. Meerdere per dienst, met een omschrijving en een bedrag.
**Bonnetjes gaan buiten het systeem om**, per mail naar de planning — er is geen
upload.

Die posten staan bewust **los van `declaration_compute()`**. Die functie berekent
de reiskostenregel met haar vier takken; onkosten worden niet berekend maar
opgegeven, en er zit geen drempel, geen tarief en geen standplaats aan vast. Ze
zitten dus ook niet in `computed_reimbursable_km`, anders lopen "wat de regel
oplevert" en "wat de koerier voorschoot" door elkaar.

Op de factuur worden ze **zonder marge** doorbelast, naar rato van de geplande
minuten — dezelfde verhouding als de uren en de reiskosten.

> ⚠ **`employmentType` is niet te verifiëren vanuit deze repo.** De markering
> *bon verwacht* hoort bij koeriers die geen zzp'er zijn, maar dat veld komt hier
> nergens voor: van `user_profiles` zijn alleen `id`, `name`, `role`,
> `pharmacy_ids` en `home_pharmacy_id` in gebruik. `declaration_expects_receipt()`
> leest het daarom via `to_jsonb(up) ->> 'employmentType'`, zodat een ontbrekende
> kolom NULL oplevert in plaats van een functie die niet aangemaakt kan worden.
> Bij NULL of leeg wordt er **geen** bon verwacht — liever geen markering dan bij
> iedereen één. De verificatiequery onderaan migratie 028 laat zien welke waarden
> er werkelijk in staan; klopt `'zzp'` niet, dan is dat één regel in die functie.

### Binnen hoeveel uur

`declaration_settings.expected_within_hours` (standaard 48) is een **verwachting**
en staat los van `token_valid_days` (30 dagen): de invullink blijft werken, ook
te laat. Dat staat zo in de mail en op de pagina, en met opzet — wie denkt dat
hij te laat is, vult helemaal niets meer in.

Het plannerscherm toont per rij hoe lang na afloop er is ingediend, of dat binnen
de termijn viel, en bij een openstaande rij hoe lang die al openstaat. Er is
daarvoor geen kolom en geen status bijgekomen: het is af te leiden uit
`submitted_at` en de eindtijd. Termijn wijzigen:

```sql
UPDATE public.declaration_settings SET expected_within_hours = 72;
```

### De invulpagina

`/declaratie?t=<token>` in dezelfde bundel, gekozen in `src/main.tsx` vóór de
sessiecontrole. `public/_redirects` stuurt op Netlify alle paden naar
`index.html`; zonder dat bestand geeft de link een 404 op de CDN.

Is de declaratie al goedgekeurd of betwist, dan opent de link nog gewoon en toont
de pagina een leesweergave: wat er is doorgegeven, met het bericht van de planning
erboven. Alleen een verlopen of onbekend token krijgt het algemene
"deze link werkt niet meer"-scherm.

De pagina praat uitsluitend met de Edge Function `shift-declaration`.
`shift_declarations` heeft geen enkele RLS-policy en geen rechten voor `anon` of
`authenticated` — ook een ingelogde planner komt er niet rechtstreeks bij. In de
database staat alleen de SHA-256-hash van het token; het token zelf wordt pas bij
het verzenden gemaakt en bestaat verder alleen in de mail.

### Omgevingsvariabelen

| Variabele | Voor | Waarvoor |
|---|---|---|
| `DECLARATION_URL` | `send-shift-mail` | basis-URL van de invulpagina, bv. `https://<app>/declaratie`. Ontbreekt hij, dan blijft een nabericht wachten in plaats van met een kapotte link uit te gaan |
| `DECLARATION_ORIGIN` | beide nieuwe functies | CORS-origin; standaard `*` (er komen geen cookies of sessies aan te pas) |
| `GOOGLE_MAPS_API_KEY` | `courier-distances` | geocoding + Distance Matrix; dezelfde sleutel als het backfill-script |

### Uitrollen

```powershell
npx supabase secrets set DECLARATION_URL=https://<app>/declaratie `
  GOOGLE_MAPS_API_KEY=<google-key>
npx supabase functions deploy shift-declaration
npx supabase functions deploy courier-distances
npx supabase functions deploy send-shift-mail    # uitgebreid met shift_followup
```

Volgorde, en stap 7 stuurt mail:

1. Migratie 018 draaien, daarna `supabase/tests/018_shift_declarations_test.sql`.
2. **Tarieven controleren** in `reimbursement_rates`. 018 zet twee startrijen neer
   (€0,23/km, drempel 10 km). Zonder rij rekent er niets, met een verkeerde rij
   rekent alles verkeerd. Wijzigen doe je met een `INSERT` met een nieuwe
   `effective_from`, nooit met een `UPDATE`: die rij zit vast in al uitbetaalde
   declaraties.
3. Standplaatsen en afstanden vullen via *Afstanden*.
4. Migratie 019 t/m 023 draaien, daarna de bijbehorende tests. 020 telt bestaande,
   nog niet goedgekeurde declaraties opnieuw door onder de aangescherpte regel;
   021 zet `declaration_overview()` opnieuw neer.
   Kijk naar de verificatiequery `sweep_zou_oppakken`: dat is het aantal mails
   dat er uitgaat zodra de cron aan gaat. Te veel? Zet `active_from` hoger.
5. Edge Functions uitrollen (zie hierboven).
6. Proefdraaien: `send-shift-mail?dry_run=1`. In een dry run staat er een
   placeholder in plaats van een token — uitgeven is een schrijfactie en zou een
   eerder verstuurde link ongeldig maken.
7. Cron aanzetten en direct verifiëren.

```sql
SELECT cron.schedule('declaration-sweep', '15 * * * *', $$
  SELECT public.declaration_sweep();
$$);
```

De bestaande `mail-send`-job pikt de naberichten vanzelf op; een derde verzendjob
is er niet.

> ⚠ **De Authorization-header luidt `'Bearer ' || <sleutel>`** — het woord
> `Bearer`, een spatie, dán de sleutel. Dit is eerder misgegaan en heeft elf dagen
> lang stilzwijgend 401's opgeleverd.

Controleren doe je in `net._http_response`, **niet** in `cron.job_run_details`:
die laatste meldt alleen of de SQL liep, niet wat de andere kant terugzei.

```sql
SELECT id, status_code, left(content, 300) AS antwoord, created
FROM net._http_response
ORDER BY created DESC
LIMIT 10;
```

Wat er klaarstaat en wat eruit ging:

```sql
SELECT o.created_at, o.status, up.name AS koerier,
       o.payload->>'shift_date' AS dienst, o.error
FROM public.mail_outbox o
JOIN public.user_profiles up ON up.id = o.courier_id
WHERE o.kind = 'shift_followup'
ORDER BY o.created_at DESC LIMIT 20;
```

Geeft een RPC vanuit de app een `PGRST202`, dan kent PostgREST de nieuwe functies
nog niet: herlaad de schema-cache (Supabase doet dat normaal zelf; anders
`NOTIFY pgrst, 'reload schema';`).

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
