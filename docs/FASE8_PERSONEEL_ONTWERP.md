# Fase 8 — personeelsadministratie los van toegangsbeheer

Status: **`employees` gebouwd (migratie 029). Twee besluiten staan open en zijn
bewust niet uitgevoerd:** de regiolaag en de koppeling van `shifts` aan
medewerkers. Beide staan hieronder uitgewerkt met een aanbeveling.

Aanleiding: Greenspeed stapt af van L1nda. De maandelijkse urenexport naar het
administratiekantoor moet uit dit systeem komen — 69 medewerkers en zo'n zestig
agenda's, tegenover de vijf koeriers en zeventien apotheken die de planner nu
kent. Dit is de eerste stap: de mensen erin krijgen.

---

## 1. Waarom niet in `user_profiles`

`user_profiles.id` heeft een foreign key naar `auth.users(id)` met
`ON DELETE CASCADE`. Dat maakt die tabel ongeschikt als personeelsadministratie:

* **Geen medewerker zonder inlogaccount.** De meesten van de 69 gaan voorlopig
  niet inloggen. 69 slapende auth-accounts aanmaken is werk zonder opbrengst, en
  elk slapend account is ook een aanvalsoppervlak.
* **Een verwijderd auth-account sleept het profiel mee**, en daarmee alles wat
  eraan hangt. Loonadministratie moet zeven jaar bewaard blijven; een `DELETE` in
  Supabase Auth mag dat niet stilletjes weghalen.

Personeelsadministratie en toegangsbeheer zijn twee dingen. `employees` is de
eerste, `user_profiles` blijft de tweede, en `employees.user_profile_id` legt de
verbinding voor wie beide heeft.

Die kolom staat op **`ON DELETE SET NULL`**. Verdwijnt het auth-account, dan
verliest de medewerker zijn inlog — niet zijn historie. Dat is de hele reden dat
deze tabel bestaat, en het is de enige regel in migratie 029 die je echt moet
onthouden.

---

## 2. In dienst is een datumbereik, geen vinkje

`employed_from` en `employed_until` (nullable = nog in dienst). Wie een
`employed_until` in het verleden heeft verdwijnt uit keuzelijsten en uit de
planning, maar een urenexport over maart bevat hem gewoon — toen werkte hij nog.

Geen apart archief, geen verwijderde rijen: één tabel, gefilterd op datum. Die
filtering staat op één plek, `employee_active_on(employee_id, date)`, plus de view
`employees_active` voor het gewone geval "wie is er vandaag in dienst". Zou elk
scherm die datumlogica zelf doen, dan is het een kwestie van tijd voor er ergens
`employed_until IS NULL` staat en een uitdienstmelding niet doorwerkt.

---

## 3. De regiolaag — conclusie: een eigen laag, niet `groups`

**Onderzocht.** `groups` is in dit schema de ketenlaag: BENU, Boots,
LambertsLeeuwen. De tabel wordt gelezen door de bezorg-app
(`supabaseService.fetchGroups()`, aangeroepen vanuit `App.tsx` en
`PharmacyOverview.tsx`) en beheerd via de service-role-functie `groups-admin.ts`;
migratie 002 heeft daar de publieke leesrechten van afgehaald. De opmerking in
die migratie spreekt van "groep/regionamen", wat suggereert dat er in de praktijk
al eens iets regio-achtigs in gezet is — reden te meer om het uit elkaar te
trekken voordat het door elkaar gaat lopen.

**Waarom `groups` het niet allebei kan dragen:**

1. **Het zijn twee onafhankelijke assen.** Een apotheek hoort bij één keten én in
   één regio. Eén `group_id` per apotheek kan er maar één van vasthouden. Zou je
   beide als rijen in `groups` zetten, dan heb je een `kind`-kolom nodig én moet
   élke lezer daarop filteren. De bezorg-app doet dat vandaag niet, en die krijgt
   dan regio's in een ketendropdown.
2. **Ze veranderen om verschillende redenen.** Een keten wisselt bij een overname
   — een commerciële gebeurtenis met gevolgen voor facturatie. Een regio wisselt
   als de planning anders wordt ingedeeld — een operationele gebeurtenis. Ze in
   één tabel zetten betekent dat een herindeling van de planning een tabel raakt
   waar de facturatie op leunt.
3. **De melding die bewaakt moet worden gaat over regio's, niet over ketens:**
   *"heeft in plaats van zijn/haar standaardfiliaal Midden Nederland gewerkt op
   Het Gooi"*. Dat is een operationele signalering. Met de ketenlaag heeft die
   niets te maken.

**Voorstel (nog niet gebouwd):** een tabel `regions(id, name)`, een
`pharmacies.region_id`, en de standaardregio van een medewerker **afgeleid uit
zijn standplaats** in plaats van apart opgeslagen. De L1nda-export levert
`roosterlaag` en `filiaal` per medewerker, maar twee plekken die hetzelfde moeten
zeggen lopen uiteen — dezelfde les als `user_profiles.pharmacy_ids` in migratie
008. Blijkt uit de importdata dat roosterlaag en filiaal structureel van elkaar
verschillen, dan is dat een reden om er alsnog een eigen veld van te maken; dat
is met de lijst in de hand te controleren.

Dit staat los van `employees` en houdt migratie 029 niet op.

---

## 4. De open vraag: waar wijst een dienst naar?

`shifts.courier_id` verwijst nu naar `user_profiles`. Zolang dat zo blijft, kun
je **geen dienst inplannen voor iemand zonder inlogaccount** — en dat is precies
het punt van deze fase.

`shifts` is gedeeld met AIrouteplanner en de bezorg-app. Daarom drie varianten,
met wat ze kosten.

### Variant 1 — `shifts.employee_id` erbij, `courier_id` behouden

*Additief. Niets breekt: de andere twee apps blijven `courier_id` lezen.*

Voor een medewerker mét account worden beide gevuld; zonder account blijft
`courier_id` leeg. `employee_id` wordt leidend voor de planner.

| | |
|---|---|
| **Voor** | Geen wijziging voor de andere apps. Terug te draaien. Gefaseerd uit te faseren zodra die apps om zijn. |
| **Tegen** | Twee kolommen die hetzelfde zeggen — precies de spiegel die migratie 008 al eens heeft afgestraft. Te ondervangen met een trigger die `courier_id` afleidt uit `employees.user_profile_id`, zodat er één schrijfrichting is. |
| **Het echte risico** | Een dienst van iemand zónder account heeft `courier_id IS NULL`. Voor de andere twee apps ziet die dienst er dan uit als **niet toegewezen**. |

### Variant 2 — `courier_id` laten wijzen naar `employees`

*Eén kolom, geen drift.*

Technisch kan dit zonder dataverlies: geef de vijf backfill-rijen dezelfde `id`
als hun `user_profiles`-rij, dan blijven alle bestaande `shifts`-rijen geldig en
hoeft alleen de foreign key om.

| | |
|---|---|
| **Voor** | Eén bron van waarheid. Geen trigger, geen uitfasering. |
| **Tegen** | Elke `JOIN user_profiles ON id = shifts.courier_id` in de andere twee repo's levert straks niets op voor medewerkers zonder profiel. Bij een `INNER JOIN` verdwijnen die diensten **stilzwijgend** uit hun schermen. |
| **Blokkade** | Niet uitvoerbaar zonder eerst beide andere repo's na te lopen, en niet terug te draaien zodra er diensten hangen aan medewerkers zonder profiel. |

### Variant 3 — een koppeltabel `shift_assignments`

| | |
|---|---|
| **Voor** | Netjes genormaliseerd; ruimte voor meerdere medewerkers per dienst. |
| **Tegen** | Dat probleem hebben we niet. Elke query erbij: conflictdetectie, `shift_declarations.courier_id`, de mailketen, de facturatie. Het meeste werk en de meeste plekken om iets te vergeten. |

### Aanbeveling

**Variant 1**, met `employee_id` leidend en `courier_id` als afgeleide spiegel die
door een trigger wordt bijgehouden — nooit met de hand.

Eén vraag beslist of dat veilig is, en die is in deze repo niet te beantwoorden:

> **Doen AIrouteplanner of de bezorg-app iets met `shifts.courier_id IS NULL`?**
> Tonen ze zo'n dienst als "open" of "beschikbaar"? Kan iemand hem oppakken?

Is het antwoord ja, dan is variant 1 niet zomaar veilig en moet er eerst een
filter in die apps bij (bijvoorbeeld: alleen diensten tonen waar `employee_id`
leeg is). Is het antwoord nee — ze tonen alleen diensten van de ingelogde
gebruiker — dan is variant 1 zonder meer de goedkoopste weg.

**Deze migratie voert daar niets van uit.** `shifts` blijft ongemoeid tot dit
besluit valt.

---

## 5. Import van de 69

`employee_import()` neemt een lijst rijen aan en koppelt op **personeelsnummer**;
ontbreekt dat, dan op voor- en achternaam. Bestaat de medewerker al, dan wordt hij
bijgewerkt en niet gedupliceerd — de lijst is dus opnieuw te draaien als er een
kolom verkeerd stond.

**Zeven medewerkers hebben geen personeelsnummer.** Die worden aangemaakt met
`personnel_number IS NULL` en komen in het scherm bovenaan te staan met een
markering. Weigeren zou betekenen dat de import handmatig moet worden aangevuld
vóór hij draait, en dan wordt hij niet gedraaid. De unieke index staat op de
kolom en niet op een expressie: Postgres laat meerdere NULL's toe, dus "geen
nummer" botst nergens mee.

De naamsplitsing bij het overnemen van de bestaande vijf gebeurt op de **eerste
spatie**: "Jan de Vries" wordt `Jan` + `de Vries`. Dat klopt voor Nederlandse
tussenvoegsels en niet voor dubbele voornamen; het scherm laat het corrigeren.

---

## 6. Wat deze fase niet doet

* `user_profiles` wordt niet verbouwd. Die tabel wordt door drie apps gebruikt en
  de auth-koppeling blijft zoals hij is voor wie wél inlogt.
* Geen auth-accounts voor mensen die niet inloggen.
* Geen medewerkers verwijderen. Uit dienst is een datum.
* `declaration_compute()` en `invoice_lines()` blijven ongemoeid.

---

## 7. Aantekening voor later: bewaartermijn

Persoonsgegevens van oud-medewerkers mogen niet onbeperkt blijven staan.
Loonadministratie zeven jaar; daarna hoort het weg.

Er moet dus ooit een opschoonroutine komen. Wat die moet doen, in volgorde van
zekerheid:

1. **Anonimiseren, niet verwijderen.** De urenhistorie moet blijven kloppen —
   totalen over 2027 mogen niet veranderen doordat iemand in 2035 is opgeschoond.
   Naam, e-mail, telefoon en personeelsnummer leegmaken; de rij laten staan.
2. **De klok begint bij `employed_until`**, niet bij de laatste dienst: iemand
   kan maanden voor zijn uitdiensttreding zijn laatste dienst hebben gedraaid.
3. **Wat er aan hangt telt mee.** `shift_declarations` bevat opmerkingen van de
   koerier en `courier_distances` bevat afstanden vanaf zijn huis — allebei
   herleidbaar. Die horen in dezelfde routine.

Bewust niet in migratie 029: een opschoonroutine die te vroeg draait vernietigt
gegevens die er nog moeten zijn, en dat is precies het soort fout dat pas jaren
later opvalt.
