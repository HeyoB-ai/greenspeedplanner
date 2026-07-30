# Fase 5 — bevestigingsmail: vastgelegde ontwerpbeslissingen

Status: **vastgelegd, nog niet gebouwd.** Dit document legt de beslissingen vast
die vóór de bouw genomen zijn, met per punt de reden. Het is bedoeld om later
terug te kunnen lezen waaróm iets zo is, niet alleen dát het zo is.

De koerier krijgt een mail zodra een dienst definitief wordt. Dat lijkt op de
SMS-herinnering, maar de eenheid is anders: bevestig je tien donderdagen uit
dezelfde roosterregel, dan is dat één afspraak en niet tien berichten. Daarmee
vervalt `shift_id` als sleutel, en dat is wat dit document uitwerkt.

Twee invarianten dragen het geheel:

> **1.** Voor elke bevestigde dienst die nog moet gebeuren bestaat er een actieve
> aankondiging die die dienst dekt. Een sweep maakt dat waar.
>
> **2.** Tijdsverloop mag een aankondiging laten vervallen of versmallen, maar
> nooit een bericht veroorzaken. Alleen een ingreep kan een bericht laten
> ontstaan — en een ingreep wordt als zodanig vastgelegd, niet uit de
> verzamelingen afgeleid.

De tweede invariant is de reden dat het venster in punt 5 werkt. De staart van
die invariant — *vastgelegd, niet afgeleid* — is niet vrijblijvend: zonder die
vastlegging is een variant die verdwijnt door tijdsverloop niet te onderscheiden
van een variant die verdwijnt doordat de planner hem wegwijzigt.

---

## 1. Eén trigger: concept → bevestigd

De mail gaat uit op de overgang `draft` → `planned` met een toegewezen koerier.
Niet bij het aanmaken van een roosterregel, niet bij het genereren van
concepten, niet bij het aanmaken van een concept-dienst.

**Waarom:** een concept is voor de koerier volledig onzichtbaar — migratie 005
dwingt dat op databaseniveau af. Melden wat de koerier niet kan zien levert een
bericht op waar hij niets mee kan, en het zou de bevestig-flow (het moment waarop
de planner zegt: dit staat vast) van zijn betekenis ontdoen.

## 2. Het subject is de afspraak, niet de dienst

Waar een bericht over gaat, hangt af van de herkomst van de dienst:

| Dienst | Subject | Gemeld als |
|---|---|---|
| `schedule_id` gevuld **en** koerier = koerier van de roosterregel | de **afspraak** (`pharmacy_schedules.id`) | "je staat vast op donderdag 07:45 bij Lamberts" |
| `schedule_id` leeg | de **dienst** (`shifts.id`) | "je bent ingepland op do 30-07 19:12 bij Lamberts" |
| `schedule_id` gevuld maar koerier ≠ koerier van de regel | de **dienst** | idem |

**Waarom die derde regel:** een roosterregel zonder vaste koerier genereert open
concepten. Wijst de planner er één handmatig aan iemand toe, dan is dat voor die
koerier geen wekelijkse afspraak maar een losse dienst. Zou je dat als afspraak
melden, dan krijgt hij een bericht over een terugkerende verplichting die hij
niet heeft — en, erger, dan geldt de volgende donderdag als "al gemeld".

## 3. De tekst komt uit de bevestigde diensten, niet uit de roosterregel

`pharmacy_schedules` levert alleen het **groeperingskenmerk** (`schedule_id`:
welke diensten horen bij één afspraak). De inhoud van het bericht — weekdag,
tijden, apotheken, vervoermiddel — wordt afgeleid uit de bevestigde `shifts`.

**Waarom:** `pharmacy_schedules` is geen beschrijving van de afspraak maar een
*generator van concepten*. `updateSchedule` verwijdert alleen toekomstige
concepten en genereert nieuwe; al bevestigde diensten houden hun oude waarden.
Wijzig je de starttijd van 07:45 naar 08:15, dan is de stand:

| | tijd |
|---|---|
| roosterregel | 08:15 |
| bevestigde donderdagen (volgende weken) | **07:45** |
| nieuwe concepten (nog niet bevestigd) | 08:15 |

Een bericht op basis van de roosterregel zou dus 08:15 aankondigen terwijl er
niets op 08:15 bevestigd is, en terwijl de koerier volgende week wél om 07:45
verwacht wordt. Het enige dat voor hem bindend is, zijn de bevestigde diensten.

**`end_date` wordt wél genoemd maar is géén signaal.** De einddatum van een
afspraak heeft geen weerslag in de bevestigde diensten en is voor de koerier
relevant ("loopt deze donderdag door of stopt hij in december"), dus de tekst
noemt hem — expliciet als horizon van de afspraak, niet als bevestigde diensten.
Hij zit **niet** in de variantverzameling van punt 5.

**Gevolg, bewust aanvaard:** een afspraak verlengen of inkorten is op zichzelf
geen nieuws en levert geen mail op. De koerier ziet de nieuwe horizon in het
eerstvolgende bericht dat om een andere reden uitgaat. Het alternatief — `end_date`
in het signaal — zou een bericht laten ontstaan over diensten die nog niet
bevestigd zijn, en dat botst met punt 1.

## 4. Twee niveaus, twee sleutels

**`courier_announcements`** — wat is er gemeld, en wat dekte dat.

```
subject_type      'schedule' | 'shift'
subject_id        UUID
courier_id        UUID
covered_variants  TEXT[]         -- welke varianten gedekt zijn, zie 5
announced_at      TIMESTAMPTZ
dirtied_at        TIMESTAMPTZ NULL   -- er is ingegrepen sinds de aankondiging, zie 5
superseded_at     TIMESTAMPTZ NULL

UNIQUE (subject_type, subject_id, courier_id) WHERE superseded_at IS NULL
```

**`mail_outbox`** — wat er verstuurd moet worden.

```
id            UUID PK
courier_id    UUID → user_profiles ON DELETE CASCADE
kind          'schedule_confirmed' | 'schedule_changed'
              | 'shift_confirmed'   | 'shift_changed'
              | 'schedule_cancelled'| 'shift_cancelled'
subject_type, subject_id      -- herleidbaarheid, geen FK
payload       JSONB NOT NULL  -- gegevens gekopieerd, zie 6
status        'pending' | 'sending' | 'sent' | 'failed'
recipient     TEXT NULL       -- pas bij verzenden bepaald, zie 6
claimed_at, sent_at, provider_message_id, error, created_at
```

Een **partiële** unieke index op de aankondigingen, hetzelfde patroon als
`shifts_schedule_date_uniq` in migratie 009: hoogstens één *actieve* aankondiging
per subject per koerier, en de geschiedenis blijft staan.

`courier_id` zit in de sleutel omdat "de afspraak is al gemeld" altijd "aan wie"
betekent. Wissel je de koerier, dan heeft de nieuwe niets gehoord.

Geen foreign key op `subject_id`: de kolom is polymorf, en een aankondiging moet
een verwijderde dienst overleven.

**`covered_variants` is een verzameling, geen hash.** De toets in punt 5 is een
insluiting (`⊆`) en geen gelijkheid, en daar heb je de losse elementen voor nodig.
Postgres doet dat rechtstreeks met `<@` en `@>`.

**Wat dit kost — expliciet.** De garantie verzwakt van *"elke dienst wordt
hoogstens één keer gemaild"* naar *"elke variant wordt hoogstens één keer
gemeld"*. Dat is precies de bedoeling — tien donderdagen op dezelfde tijd zijn
één afspraak — maar het is een zwakkere uitspraak, en hij leunt op de juistheid
van de subject-bepaling (punt 2) en van de variantdefinitie (punt 5) in plaats van
op een primaire sleutel. De SMS-log blijft daarom ongemoeid met `shift_id` als
sleutel: twee mechanismen met verschillende garanties, naast elkaar, met opzet.

## 5. Het venster, en waarom tijdsverloop geen bericht kan veroorzaken

### Het venster

De sweep kijkt naar bevestigde diensten die **nog niet begonnen zijn**:

```sql
(shift_date + start_time) AT TIME ZONE 'Europe/Amsterdam' > now()
```

Exact dezelfde uitdrukking als in `sms_due_shifts` (migratie 012), zodat er in de
hele planner één definitie van "staat nog te gebeuren" is.

**Waarom niet alle diensten:** dan zou een afspraak die in maart 07:45 was en
sinds april 08:15 is, dat verschil voor altijd blijven melden. De mail gaat over
wat de koerier nog moet doen, niet over zijn geschiedenis.

### Waarom dat venster geen berichten laat ontstaan

Een venster dat met de klok meeschuift, verandert van inhoud zonder dat iemand
iets doet. Zou het signaal een *gelijkheidstoets* zijn ("wijkt de verzameling af
van wat we meldden?"), dan zou de laatste 07:45-donderdag die in het verleden
valt de verzameling van `{07:45, 08:15}` naar `{08:15}` brengen en een
wijzigingsmail veroorzaken. Precies dat mag niet.

Daarom is het signaal een **insluitingstoets**:

> Staat er een variant vóór me die de actieve aankondiging niet dekt?

De aankondiging bewaart wát ze gedekt heeft (`covered_variants`). De toets kijkt
dus niet of de verzameling gelijk is, maar of er iets **bij** is gekomen. En bij
komen kan alleen doordat iemand een dienst bevestigt of wijzigt.

### Wat een variant is

Eén variant per onderscheidbare verplichting:

```
weekdag(uit shift_date) | start_time | budgeted_end_time | transport_mode | gesorteerde apotheek-ids
```

Bij een `shift`-subject is dat er per definitie één, met de datum in plaats van de
weekdag.

Bewust **niet** in de variant:

- **de losse datums en het aantal diensten** — anders is elke volgende
  bevestiging opnieuw nieuws en is het groeperen zinloos (bevestig je week 11 op
  dezelfde tijd, dan hoort er niets uit te gaan);
- **`end_date`** — zie punt 3;
- **`car_is_own`** — eigen of bedrijfsauto is een administratieve vraag, geen
  verandering in wat de koerier moet doen. `transport_mode` zit er wél in: wie een
  fiets verwacht en een auto nodig heeft, heeft een probleem.

### Een variant die verdwíjnt is soms óók nieuws

De insluitingstoets alleen is niet genoeg. Staat er 07:45 én 08:15 bevestigd en
zet de planner de 08:15-diensten terug naar 07:45, dan is `V = {07:45} ⊆ C` — de
toets ziet niets nieuws en zou zwijgen, terwijl de koerier verteld is dat hij om
08:15 komt en dat niet meer waar is.

Dat is niet met verzamelingen op te lossen: `V ⊆ C` met `C ⊄ V` ziet er *identiek*
uit of de variant uit het venster liep (tijdsverloop, terecht stil) of werd
weggewijzigd (ingreep, wel nieuws). De onderliggende gebeurtenis verschilt, de
uitkomst van de rekensom niet.

**Daarom wordt de ingreep vastgelegd in plaats van afgeleid.** Een trigger op de
kolommen die de variant vormen zet `dirtied_at` op de actieve aankondiging (punt
8). De sweep weet daarmee of een versmalling van de klok komt of van een mens.

Bewust een vlag en geen `superseded_at` uit de trigger: bij superseden zou een
wijziging die per saldo niets verandert (aanpassen en meteen terugzetten) alsnog
een bericht opleveren. Met een vlag vergelijkt de sweep de standen en zwijgt hij
als ze gelijk zijn.

### Het volledige besluit per (subject, koerier)

`V` = varianten over de bevestigde diensten in het venster. `C` =
`covered_variants` van de actieve aankondiging. `bij` = `V ⊄ C` (er is iets
bijgekomen), `af` = `C ⊄ V` (er is iets verdwenen).

| Situatie | Handeling | Bericht? |
|---|---|---|
| `V` niet leeg, geen actieve aankondiging | aankondigen met `covered := V` | **ja** — `*_confirmed` |
| `bij` | oude op `superseded_at`, nieuwe met `covered := V` | **ja** — `*_changed` |
| vlag gezet én `af` (en niet `bij`) | idem | **ja** — `*_changed` |
| vlag gezet, `V` = `C` | alleen de vlag wissen | **nee** |
| geen vlag, `af` | `covered := C ∩ V` | **nee** — tijdsverloop |
| `V` leeg, actieve aankondiging | op `superseded_at` | **nee** |

De onderste twee regels zijn wat de klok doet: versmallen en laten vervallen,
allebei zwijgend. Een bericht vereist óf iets nieuws in `V`, óf een vastgelegde
ingreep — en de klok kan geen van beide bewerken.

Regel 5 blijft nodig náást de vlag: zonder versmallen zou een variant die uit het
venster liep voor altijd als "al gemeld" blijven gelden, en zou een terugdraaiing
naar die variant later niet meer als nieuws herkend worden.

Twee gevolgen die het waard zijn om te noemen:

- **Versmallen houdt een terugdraaiing detecteerbaar.** Is 07:45 uit het venster
  verdwenen en daarmee uit `covered`, en zet de planner de afspraak later terug
  naar 07:45, dan is dat weer nieuws. Zonder versmallen zou `covered` die variant
  voor altijd als "al gemeld" beschouwen.
- **Een afspraak die leegloopt en later weer gevuld wordt, is opnieuw nieuws.**
  De aankondiging verviel zwijgend toen er niets meer vóór lag; bevestigt de
  planner er maanden later weer donderdagen, dan krijgt de koerier bericht. Dat is
  gewenst: hij had niets meer staan.

## 6. De outbox kopieert gegevens, hij verwijst niet

`payload` bevat alles om het bericht te renderen: datums, tijden, apotheeknamen,
de naam van de koerier. Geen foreign key naar `shifts`.

**Waarom:** een afmelding gaat per definitie over een dienst die niet meer
bestaat. Zou de outbox naar `shifts` verwijzen, dan is de rij weg op het moment
dat je hem nodig hebt — en met `ON DELETE CASCADE` verdwijnt het bericht mee.
Dit is de reden dat het een outbox is en geen log.

`recipient` wordt pas bij het verzenden bepaald en daarna vastgelegd. Zo werkt een
gecorrigeerd adres nog door op een bericht dat al klaarstaat, en zie je achteraf
waar het écht naartoe ging.

## 7. Inschrijven doet een sweep, en alleen de sweep

De sweep draait elke **vijf minuten**. De bevestig-knop roept niets aan.

**Waarom geen tweede pad:** de sweep is zelfherstellend en een pure functie van
de databasestand. Een directe aanroep vanuit de knop voegt alleen oppervlak toe —
een extra faalpad, een extra plek waar de logica kan gaan afwijken — zonder dat
er iets bijkomt: vijf minuten is ruim voor een dienst die weken vooruit ligt.

**Waarom niet de knop als bron:** `confirmShifts` doet
`.in('id', ids).eq('status','draft')` zonder `RETURNING`
(`plannerService.ts:309`), dus de client weet welke diensten hij vroeg maar niet
welke daadwerkelijk omgingen — al bevestigde diensten worden stil overgeslagen.
Een samenvatting op basis van de clientintentie zou diensten noemen die niets
nieuws waren.

## 8. Drie triggers op bevestigde diensten

De sweep kan twee dingen niet zien: wat er verdwenen is, en of een versmalling van
een mens kwam. Daar zijn triggers voor.

**Ingreep vastleggen** — `AFTER UPDATE OF shift_date, start_time,
budgeted_end_time, transport_mode ON shifts` waar `status = 'planned'`, plus
`AFTER INSERT OR DELETE ON shift_pharmacies` voor een bevestigde dienst → zet
`dirtied_at` op de actieve aankondiging van dat subject en die koerier. Géén
outbox-rij: de sweep bepaalt of er werkelijk iets veranderd is en levert de tekst
met de actuele stand.

Dit is de trigger die in een eerdere versie van dit document ontbrak, waardoor een
weggewijzigde variant stil verdween. `courier_id` zit er bewust niet bij: een
koerierwissel gaat langs de twee triggers hieronder.

**Afmelden** — twee triggers, want in beide gevallen kan een sweep niet zien wat
er verdwenen is:

- `BEFORE DELETE ON shifts` waar `OLD.status = 'planned'` en koerier gevuld → een
  `shift_cancelled`-rij met de gegevens uit `OLD` gekopieerd. **Vóór** het
  verwijderen en niet erna, want `shift_pharmacies` ruimt zichzelf op via
  `ON DELETE CASCADE` — in een `AFTER`-trigger zijn de apotheeknamen al weg.
- `AFTER UPDATE OF courier_id ON shifts` waar `status = 'planned'` en de koerier
  daadwerkelijk wijzigt → een afmelding voor de **oude** koerier. De nieuwe
  koerier wordt door de sweep opgepakt: die heeft geen aankondiging.

**Waarom de tweede:** bij een koerierwissel verdwijnt er voor de oude koerier een
dienst zonder dat er een rij verwijderd wordt. Zonder deze trigger hoort hij niets
en staat hij voor niets klaar — de duurste stilte in dit ontwerp.

Beide triggers vuren alleen voor diensten die nog moesten gebeuren (zelfde
vensteruitdrukking als punt 5). Een afgeronde dienst verwijderen is administratie,
geen nieuws.

## 9. Bundelen per koerier bij het verzenden

De outbox bevat losse feiten; de verzender bundelt alle geclaimde feiten van
dezelfde koerier in één mail, ook als ze over verschillende afspraken gaan.

**Waarom:** de datum van een dienst is niet te wijzigen — `ShiftForm` heeft geen
datumveld (`ShiftForm.tsx:21`). Een dienst verzetten is dus verwijderen en
opnieuw aanmaken, en dat levert twee feiten op: "do 20-08 vervalt" en "je staat
nu op vr 21-08". Zonder bundeling zijn dat twee losse mails die elkaar lijken
tegen te spreken, in willekeurige volgorde in de inbox.

## 10. Elk bericht is een momentopname onder één peildatum

Boven de inhoud staat één regel: `Stand op 30-07-2026:`. Daaronder worden alle
varianten genoemd, elk met de datum waarop hij ingaat — en **nooit** met een
datum waarop hij ophoudt:

```
Stand op 30-07-2026:

Je vaste dienst is gewijzigd. Dit staat er nu:
- vanaf 13-08-2026: elke donderdag 07:45-12:00 bij Lamberts Apotheek, met de fiets
- vanaf 22-10-2026: elke donderdag 08:15-12:30 bij Lamberts Apotheek, met de fiets
Deze afspraak loopt t/m 31-12-2026.
```

**Waarom volledig en niet alleen de nieuwe variant:** de oude staat nog bevestigd
en de koerier wordt daar volgende week op verwacht. Alleen de nieuwe noemen zou
hem op de verkeerde tijd laten komen; verwijzen naar de app maakt de mail
afhankelijk van een tweede handeling die hij niet per se doet.

**Waarom de peildatum.** De vingerafdruk bevat bewust geen datums (punt 5), want
anders zou elke volgende bevestiging opnieuw nieuws zijn. Gevolg: een dienst die
later op een oude tijd bevestigd wordt, verandert `V` niet en levert dus géén
mail op. Elke uitspraak in het bericht die *vooruit* kijkt kan daardoor stil
onwaar worden — niet alleen een einddatum, maar ook "elke donderdag 08:15 vanaf
22-10", want er kan daarna alsnog een 07:45 bijkomen.

Dat is niet te repareren door zorgvuldiger te formuleren; het zit in het signaal.
Wat de peildatum wél doet, is de **soort fout** veranderen: alles onder die regel
is waar op dat moment, en blijft dat. Een bericht dat is ingehaald door de
werkelijkheid is daarmee *onvolledig* in plaats van *onwaar* — een veel goedkopere
fout, en de enige die ook het rommelige geval dekt waarin twee tijden door elkaar
heen lopen.

Daarom hoeft `end_date` geen aparte formulering: "Deze afspraak loopt t/m
31-12-2026" valt onder dezelfde peildatum.

**Wat hier is afgevallen.** Een eerdere opzet bakende de niet-laatste varianten af
(`van 13-08 t/m 15-10`) en liet alleen de laatste openstaan. Dat leek volledig,
maar het maakte precies de belofte die het signaal niet kan waarmaken. Het
alternatief — de grens van niet-laatste varianten in de vingerafdruk opnemen — is
correct maar maakt de vingerafdruk volgorde-afhankelijk: of een variant zijn grens
meedraagt zou afhangen van welke variant toevallig de laatste is. Dit onderdeel is
al twee keer op een subtiliteit in het signaal gestruikeld (de klok-versmalling en
het spiegelbeeld); een derde erbij om een bijzin te redden is een slechte ruil.

## 11. Hoe dubbele berichten voorkomen worden

Drie gates, alle drie atomair, alle drie hetzelfde patroon: alleen wie de rij
wint, mag handelen.

| Risico | Wat het tegenhoudt |
|---|---|
| Twee bevestigingsacties in dezelfde minuut, of twee planners tegelijk | Eerste aankondiging: `INSERT … ON CONFLICT DO NOTHING RETURNING id` op de partiële unieke index. Beide transacties proberen de rij, één wint, alleen de winnaar schrijft een outbox-rij. |
| Twee sweeps zien tegelijk een nieuwe variant of een vastgelegde ingreep | Vervolg-aankondiging: `UPDATE courier_announcements SET superseded_at = now() WHERE id = $1 AND superseded_at IS NULL RETURNING id`. De `UPDATE` is de claim; wie geen rij terugkrijgt, doet niets en schrijft dus ook geen outbox-rij. |
| Herstart tijdens het verzenden | `UPDATE mail_outbox SET status='sending' WHERE id = $1 AND status='pending' RETURNING id`. Lege uitkomst betekent dat een ander proces hem heeft. Crasht het proces na de claim, dan blijft de rij op `sending` staan en gaat er niets meer uit — fail-closed en zichtbaar, dezelfde keuze als bij de SMS. |

Het versmallen (regel 3 in punt 5) heeft geen gate nodig: twee sweeps berekenen
dezelfde uitkomst, en de schrijfactie is idempotent.

## 12. Vullen bij installatie

De migratie schrijft meteen een aankondiging in — mét `covered_variants` — voor
elk subject dat op dat moment bevestigde diensten in het venster heeft.

**Waarom:** zonder die vulling meldt de eerste sweep de hele bestaande planning
aan alle koeriers. Dezelfde valkuil als bij de SMS, waar de eerste echte run voor
élke bevestigde dienst binnen 24 uur een bericht stuurt — daar is de dry run het
vangnet, hier is het de vulling. Van de beslissingen in dit document is dit de
makkelijkste om te vergeten en de duurste om te herstellen: verstuurde mail is
niet terug te halen.

---

## Nog te beslissen

Niet besloten — hier expliciet genoteerd zodat het niet stilzwijgend ingevuld
wordt tijdens de bouw.

- **Reply-to en de postbus.** Antwoorden op een mail is natuurlijk gedrag, anders
  dan bij de SMS. `planning@greenspeedkoeriers.nl` moet dus een postbus zijn die
  iemand leest, of er moet een `Reply-To` naar een adres dat dat wel is. Anders
  verdwijnt "ik kan niet" in het niets — precies het bericht waarvoor deze mail
  bestaat.
- **Afzenderdomein.** Nu `planning@greenspeedkoeriers.nl` (**mét** s, testdomein,
  DKIM geverifieerd). Het echte domein is `greenspeedkoerier.nl` (**zónder** s) en
  moet geverifieerd zijn vóór er naar echte koeriers gemaild wordt. Het adres komt
  in een secret (`MAIL_FROM` + `MAIL_FROM_NAME`, want Brevo wil de afzender als
  `{ name, email }`), zodat omzetten geen codewijziging vergt. Overweeg een
  `MAIL_ALLOWLIST`-secret zolang het testdomein in gebruik is: leeg maken is dan
  de bewuste stap "we gaan live".
- **De berichttekst zelf**, zoals bij de SMS pas aan het eind.

## Raakvlak met de SMS-herinnering

De twee mechanismen staan naast elkaar en delen niets behalve de
vensteruitdrukking:

| | SMS (fase 4) | Mail (fase 5) |
|---|---|---|
| Trigger | 24 uur vóór aanvang | bevestigen (`draft` → `planned`) |
| Eenheid | de dienst | de afspraak, of de losse dienst |
| Sleutel | `shift_sms_log.shift_id` | actieve aankondiging per subject per koerier |
| Bron van de tekst | de dienst zelf | de bevestigde diensten in het venster |
| Bij wijziging | geen bericht, telefonisch afstemmen | nieuw bericht zodra er een variant bij komt |
| Bij annulering | geen bericht | afmelding uit de outbox |

Dat de SMS geen correctiebericht stuurt en de mail wel, is geen inconsistentie:
een SMS gaat over morgen en wordt telefonisch afgestemd, een mail kan over een
dienst van twee maanden later gaan en is dan het enige dat de koerier heeft.
