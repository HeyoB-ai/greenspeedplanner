# Fase 6 — nadeclaratie: werkelijke duur en reiskosten

Status: **gebouwd, nog niet aangezet.** Migraties 018 en 019 staan klaar, de
Edge Functions zijn geschreven, de schermen zitten in de app. De cron staat nog
uit en het is nog niet uitgerold — zie *Uitrollen* onderaan.

Na afloop van een dienst krijgt de koerier een mail met een link. Achter die link
vult hij twee dingen in: hoe lang de dienst werkelijk duurde, en of hij
reiskosten declareert. De planner ziet daarna per dienst wat de koerier opgaf
naast wat het systeem berekende, met het verschil erbij.

---

## 1. De rekenregel

```
eigen auto?
├─ ja  → opgegeven km's × autotarief          (regel: own_car)
└─ nee → andere apotheek dan de standplaats?
         ├─ ja  → volledige afstand vergoed    (regel: other_pharmacy)
         └─ nee → afstand − drempel, min. 0    (regel: above_threshold / none)
```

Afstand is de **enkele reis**, van het woonadres van de koerier naar de apotheek
van díe dienst, over de werkelijke route (niet hemelsbreed). De drempel is 10 km
en staat per tarief in de database, dus hij is instelbaar en kan met een
tariefwijziging meebewegen.

Twee dingen zijn tegenintuïtief en bewust zo gekozen:

* **Bij eigen auto vervalt de drempel volledig.** Ook wie op 2 km woont krijgt
  alle opgegeven kilometers vergoed.
* **Bij een andere apotheek dan de standplaats vervalt de drempel ook.** Wie op
  3 km van zijn standplaats woont en naar een apotheek op 4 km gaat, krijgt die
  4 km — ook al rijdt hij nauwelijks verder. Dit volgt uit de regel en is zo
  bevestigd.

Bij eigen auto geeft de koerier zelf het aantal kilometers op. Dat is niet
controleerbaar en dat is geaccepteerd. Het systeem berekent er wél een
referentieafstand naast, puur om afwijkingen zichtbaar te maken — niet om af te
wijzen. In het plannerscherm staan de twee getallen daarom naast elkaar.

De regel staat op één plek: `declaration_compute()` in migratie 018. De sweep,
het indienen en het hertellen lopen allemaal langs die ene functie, zodat er geen
tweede versie van de waarheid kan ontstaan. In de frontend staat geen tarief en
geen drempel: `declaration_overview()` levert kilometers, tarief én bedrag al
uitgerekend aan.

### `computed_reimbursable_km` is een berekening, geen claim

De rekenregel draait ook als de koerier *nee* zegt op de vraag of hij reiskosten
declareert: bij een fietsdienst boven de drempel staat er dan gewoon een getal in
`computed_reimbursable_km`. Wat er te betalen valt is dus altijd
**`claims_travel` × `computed_reimbursable_km`**, en nooit dat tweede getal
alleen. Het plannerscherm toont zo'n rij als *geen claim*. Wie hier later een
uitbetaling op bouwt moet die eerste kolom meenemen.

### Nul is niet hetzelfde als onbekend

Ontbreekt de standplaats, de afstand of het tarief, dan valt de berekening terug
op wat wél kan, en zet `computed_incomplete` met een reden. Er wordt nooit
stilzwijgend 0 vergoed. Een planner die "€ 0,00" ziet moet kunnen weten of dat
"binnen de drempel" betekent of "we weten het niet".

### Welke apotheek bij een dienst over meerdere apotheken

`shift_pharmacies` is m:n, dus een dienst kan meer dan één apotheek hebben.

De standplaatstak geldt alleen als **álle** apotheken van de dienst de
standplaats zijn. Zit er één andere bij, dan moet de koerier ergens anders heen
en is het `other_pharmacy`; de bestemming is dan de apotheek met de **grootste**
bekende afstand. Waar hij werkelijk begonnen is valt niet vast te stellen, en dan
is de keuze die de koerier niet benadeelt de enige verdedigbare. Welke apotheek
het werd staat in `computed_pharmacy_id` en het plannerscherm toont hem.

Dit is aangescherpt in **migratie 020**. Daarvóór won de standplaats zodra hij
érgens tussen de apotheken zat, waardoor een dienst bij de eigen standplaats én
een apotheek verderop onder de drempelregel viel.

### Een ontbrekende afstand is onbekend, niet nul en niet "de verste bekende"

De bestemming in de `other_pharmacy`-tak wordt gekozen met een join op
`courier_distances`. Een apotheek zonder bekende afstand valt uit die join weg,
en dan wint er een die dichterbij ligt: de uitkomst is dan geen maximum maar een
ondergrens. Zonder maatregel is dat een stilzwijgend te lage vergoeding.

Sinds migratie 020 geldt daarom: zit er in de dienst een apotheek waarvoor geen
afstand bekend is, dan is "de verste" niet vast te stellen. Het bedrag wordt
`NULL` en de reden noemt de apotheken bij naam, zodat de planner ze kan aanvullen
en op Hertellen kan drukken. Bij eigen auto verandert er niets: daar komt het
bedrag van de koerier en is de afstand alleen referentie.

---

## 2. Het woonadres wordt niet opgeslagen

De koerier (of de planner namens hem) voert het adres eenmalig in een formulier
in. Dat gaat naar de Edge Function `courier-distances`, die het geocodeert, de
route-afstanden berekent naar álle apotheken waar de koerier aan gekoppeld is, en
**alleen die afstanden** wegschrijft in `courier_distances`.

Daarmee is er geen bewaartermijn op adresgegevens nodig, en levert een lek
niemands woonplaats op. De functie logt het adres ook niet — een logregel is ook
een bewaarplaats — en geeft de gevonden coördinaten niet terug aan het scherm.
Het invoerveld wordt na een geslaagde berekening leeggemaakt.

Waarom meteen álle apotheken en niet alleen de standplaats: zonder afstand naar
een apotheek waar de koerier soms komt, blijft de tak *andere apotheek* van de
regel onberekenbaar en is elke dienst daar onvolledig.

`source` legt vast hoe hard het getal is: `route` bij een geslaagde
routeberekening, `fallback` bij hemelsbreed × 1,35 (omrijfactor) als de
routeberekening niets oplevert, en `manual` bij invoer door de planner.

---

## 3. De link: toegang zonder inloggen

De koerier klikt vanuit zijn mailbox en moet kunnen invullen **zonder in te
loggen**. Anders vult niemand het in.

* Het token is 32 bytes cryptografisch random (hex, 64 tekens).
* In de database staat **alleen de SHA-256-hash**, nooit het token zelf.
* Vervaldatum: dienstdatum + 30 dagen (instelbaar in `declaration_settings`).
  Een herverzending verlengt die datum niet.
* Het token hoort bij precies één declaratie. De invulpagina stuurt nooit een
  `declaration_id` mee; het token is het enige aanknopingspunt, dus er is niets
  om te buigen naar een andere dienst.
* `shift_declarations` heeft **geen enkele RLS-policy** en geen rechten voor
  `anon` of `authenticated`. De pagina praat uitsluitend met de Edge Function
  `shift-declaration`, die als service-role draait — in lijn met hoe migratie 017
  is opgezet. Ook een ingelogde planner komt niet rechtstreeks bij die tabel.
* Onbekend, verlopen en al-afgehandeld geven alle drie hetzelfde antwoord. Uit
  het proberen van tokens valt zo niets te leren.

### Waarom het token pas bij het verzenden gemaakt wordt

De sweep zet bij het aanmaken een hash neer van een token dat niemand krijgt.
Pas de verzender vraagt met `declaration_issue_token()` een echt token op, zet het
in de mail, en wat in de database achterblijft is opnieuw alleen een hash.

Het alternatief — het token in de outbox-payload — zou betekenen dat één
leesrecht op `mail_outbox` een stapel werkende links oplevert, en dat die links
daar ook ná verzending blijven liggen. De prijs is dat een tweede uitgifte de
vorige link ongeldig maakt. Dat is hier goedkoop: een nabericht gaat één keer per
dienst uit, en een tweede uitgifte gebeurt alleen als de eerste verzending
mislukte.

### Corrigeren mag, tot de planner kijkt

Na indienen blijft de link werken zolang de status `submitted` is. Zodra de
planner goedkeurt of betwist, doet hij niets meer. Een koerier die zich vertypt
hoeft dus niet te bellen, en een afgehandelde declaratie kan niet meer onder de
planner vandaan veranderen.

### De formulering in het formulier

Bij eigen auto staat er woordelijk: *"totaal gereden kilometers, vanaf vertrek
thuis tot terugkomst thuis"* — in de mail én op de pagina, in dezelfde woorden.
Zonder die definitie telt de een de bezorgroute mee en de ander niet, en zijn de
opgaves achteraf niet met elkaar te vergelijken.

---

## 4. De mailketen: wat hergebruikt is en wat niet

**Hergebruikt:** `mail_outbox`, de dispatchfuncties uit 017 en de Edge Function
`send-shift-mail`. Er is één berichtsoort bijgekomen: `shift_followup`.

**Niet hergebruikt:** `mail_upcoming_subjects`. Die view filtert op
`mail_is_upcoming()` en `status = 'planned'` — precies het tegenovergestelde van
wat hier nodig is, want een nabericht gaat over een dienst die al gewéést is.
Ook de `courier_announcements`-machinerie met `covered_variants` en
`superseded_at` blijft buiten beeld: die bestaat om herhaalde aankondigingen te
vergelijken, en een nabericht is eenmalig per dienst.

`mail_sweep()`, `mail_upcoming_subjects` en `mail_is_upcoming()` zijn **niet
gewijzigd**. Aan `mail_outbox` zijn alleen de twee CHECK-constraints verruimd
(één `kind` en één `status` erbij).

### Idempotentie

De `unique` op `shift_declarations.shift_id` is de poort. Draaien er twee sweeps
tegelijk, dan wint er één: de tweede krijgt niets terug uit
`INSERT … ON CONFLICT DO NOTHING RETURNING` en slaat de dienst over — zelfde
patroon als in `mail_sweep()`.

### De vloer onder de eerste run

`declaration_settings.active_from` staat standaard op de installatiedatum.
Zonder dat getal pakt de eerste sweep élke afgelopen dienst uit de hele historie
op en stuurt daar mail over. Dezelfde valkuil als de vulling onderaan migratie
016, en verstuurde mail is niet terug te halen.

### De leeftijdscontrole

`declaration_expire_stale()` draait aan het begin van elke verzendrun en zet
wachtende naberichten over diensten van langer dan `max_age_days` (standaard 14)
geleden op `expired`, met de reden erbij. Zonder die stap stuurt een wachtrij die
een tijd heeft stilgestaan — een verkeerd getypte sleutel, een allowlist die
dichtstond — alsnog mail over diensten van weken terug zodra hij weer loopt.

De declaratie zelf blijft staan: de planner kan hem nog behandelen, er gaat
alleen geen mail meer over.

### Een bundel krijgt één uitkomst, dus een linkloos bericht moet eruit

De verzender claimt alle wachtende post van een koerier in één UPDATE en legt
daarna één uitkomst op de hele bundel vast (fase 5, punt 9). Lukt het niet om
voor een nabericht een invullink te maken — geen `DECLARATION_URL`, of de
declaratie is intussen afgehandeld — dan zou dat bericht als `sent` worden
afgevinkt terwijl de tekst nooit is uitgegaan.

`declaration_release()` zet zo'n rij terug op `pending`. Hij gaat mee zodra de
link wél gemaakt kan worden, en blijft dat misgaan, dan vangt de leeftijdscontrole
hem af. Wachten is hier de veilige kant: een gemiste mail zie je in de outbox
staan, een verdwenen mail niet.

---

## 5. Wat er níet in zit

* Geen woonadressen in de database.
* Geen tarieven of drempels in de frontend.
* Geen sleutels of secrets in `VITE_`-variabelen. De anon-sleutel gaat mee als
  Authorization-header naar de Edge Functions omdat Supabase die eist; hij geeft
  op zichzelf nergens toegang toe, want `shift_declarations` heeft geen policy.
* Geen wijziging aan de keten van fase 5.

### Verhouding tot `shift_time_reports` (migratie 006)

Die tabel bevat de uit **scandata** berekende tijd van de bezorg-app.
`shift_declarations` bevat wat de koerier ná afloop **zelf** opgeeft, via een link
in de mail en zonder in te loggen. Twee bronnen die elkaar kunnen controleren;
daarom zijn ze niet samengevoegd. `shift_time_reports.own_car_km` blijft van die
andere keten.

---

## 6. Wat er in de database bij komt

| Object | Migratie | Waarvoor |
|---|---|---|
| `user_profiles.home_pharmacy_id` | 018 | standplaats; bepaalt de hoofdvertakking |
| `courier_distances` | 018 | afstand koerier ↔ apotheek, zonder adres |
| `reimbursement_rates` | 018 | tarief + drempel, met ingangsdatum |
| `shift_declarations` | 018 | één rij per dienst: opgave én berekening |
| `declaration_compute()` | 018, 020 | de rekenregel, op één plek |
| `declaration_settings` | 019 | vloer, maximale leeftijd, geldigheid link |
| `declaration_sweep()` | 019 | afgelopen diensten → declaratie + bericht |
| `declaration_expire_stale()` | 019 | te oude post afsluiten |
| `declaration_issue_token()` | 019 | token bij het verzenden |
| `declaration_by_token()` / `declaration_submit()` | 019 | de invulpagina |
| `declaration_overview()` / `declaration_review()` | 019 | de plannerkant |

Twee afwijkingen van de oorspronkelijke opdrachtomschrijving, allebei omdat het
schema anders is dan daar aangenomen:

1. `public.profiles` bestaat niet; het is `public.user_profiles` (migratie 001).
2. `pharmacies.id` is **TEXT**, geen UUID. Alle apotheekverwijzingen zijn dus
   TEXT.

---

## 7. Uitrollen

De volgorde is niet vrijblijvend: stap 7 stuurt mail.

1. **Migratie 018** draaien (dry-run met `ROLLBACK;` mag eerst), daarna
   `supabase/tests/018_shift_declarations_test.sql`.
2. **Tarieven controleren.** 018 zet twee startrijen neer (€0,23/km, drempel
   10 km, ingangsdatum 2025-01-01). Zonder rij rekent er niets, met een verkeerde
   rij rekent alles verkeerd. Een tariefwijziging is voortaan een `INSERT` met
   een nieuwe `effective_from`, nooit een `UPDATE` van een bestaande rij: die rij
   zit vast in al uitbetaalde declaraties.
3. **Standplaatsen en afstanden vullen** via *Afstanden* in de planner.
   ⚠ Zolang apotheken geen adresgegevens hebben, kan er voor die apotheken geen
   afstand berekend worden. Het scherm benoemt ze en biedt handmatige invoer.
4. **Migratie 019 en 020** draaien, daarna
   `supabase/tests/019_declaration_mail_test.sql` en
   `supabase/tests/020_declaration_branch_test.sql`. 020 telt bestaande, nog niet
   goedgekeurde declaraties opnieuw door onder de aangescherpte regel.
   Controleer meteen de verificatiequery *sweep_zou_oppakken*: dat is het aantal
   mails dat er uitgaat zodra de cron aan gaat. Loopt dat in de tientallen, zet
   `active_from` dan hoger.
5. **Edge Functions uitrollen** (`shift-declaration`, `courier-distances`) en
   `send-shift-mail` opnieuw, want die is uitgebreid met de nieuwe berichtsoort.
6. **Proefdraaien** met `?dry_run=1`. De dry run geeft `<token wordt pas bij echt
   verzenden gemaakt>` in de link: uitgeven is een schrijfactie en zou een eerder
   verstuurde link ongeldig maken.
7. **Pas dan de cron aanzetten**, en direct verifiëren in `net._http_response`.

### De cron

```sql
SELECT cron.schedule('declaration-sweep', '15 * * * *', $$
  SELECT public.declaration_sweep();
$$);
```

De verzender uit fase 5 (`mail-send`) pikt de naberichten vanzelf op; er is dus
geen derde verzendjob nodig.

> ⚠ **De Authorization-header luidt `'Bearer ' || <sleutel>`.** Het woord
> `Bearer`, een spatie, dán de sleutel. Dit is eerder misgegaan en heeft elf
> dagen lang stilzwijgend 401's opgeleverd.

Controleren doe je in `net._http_response`, **niet** in `cron.job_run_details`:
die laatste meldt alleen of de SQL liep, niet wat de andere kant terugzei.

```sql
SELECT id, status_code, left(content, 300) AS antwoord, created
FROM net._http_response
ORDER BY created DESC
LIMIT 10;
```

---

## Nog te beslissen

* **Wie voert het adres in.** Nu doet de planner dat in het scherm *Afstanden*.
  Een eigen adresformulier voor de koerier (met dezelfde token-aanpak als de
  invulpagina) kan later; het datamodel hoeft er niet voor te veranderen, want
  het adres wordt toch niet bewaard.
* **Uitbetaling.** Een goedgekeurde declaratie is nu een status, geen boeking.
  Wat er met de bedragen richting de administratie gebeurt is nog niet belegd.
* **Rijafstand voor fietsdiensten.** De afstand wordt met `mode=driving`
  berekend, ook voor fietsdiensten: dat is de maat die iedereen kan nalopen. Of
  dat voor de fiets de bedoelde maat is, is een afspraak die nog bevestigd moet
  worden.
