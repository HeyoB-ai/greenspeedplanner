# Fase 3 — bevestigingsmail: vastgelegde ontwerpbeslissingen

Status: **vastgelegd, nog niet gebouwd.** Dit document legt de beslissingen vast
die vóór de bouw genomen zijn, met per punt de reden. Het is bedoeld om later
terug te kunnen lezen waaróm iets zo is, niet alleen dát het zo is.

Achtergrond: bij elke fietsenstalling komt een QR-code die de koerier scant. Dat
verandert het karakter van de tijdregistratie fundamenteel — zie beslissing 1.

---

## 1. Het dienstvenster wordt gemeten, niet berekend

```
start = eerste scan bij de apotheek − 15 min
eind  = QR-scan bij de stalling
```

De 15 minuten zijn `PRE_MARGIN_MIN`: de betaalde voorbereidingstijd vóór de eerste
scan, vastgelegd als **bedrijfsafspraak** (zie
[`src/timesheet/PARAMETERS.md`](../src/timesheet/PARAMETERS.md)). Geen schatting,
dus ook niet te ijken. Het aantal pakketten doet er niet toe: of er 2 of 200
klaarstaan, alleen het tijdstip van de eerste scan telt.

**Waarom:** tot nu toe was de eindtijd afgeleid — laatste deurscan + berekende
terugreis + afrondmarge — en dus een voorstel dat de koerier moest corrigeren. Met
een scan bij de stalling is het eind een waarneming. Een gemeten getal hoeft niet
geijkt, niet verdedigd en niet uitgelegd. Dat is de reden dat er hierna zo veel
constanten vervallen (zie het slot van dit document).

## 2. `shift_id` wordt vastgelegd op het scanmoment, niet achteraf afgeleid

De stallingscan slaat direct op bij welke dienst hij hoort.

**Waarom:** een stallingscan draagt alleen koerier + tijdstip. Anders dan bij
pakketten is er géén `pharmacyId` om op te splitsen, dus de bestaande
disambiguatie (pakketten verdelen over diensten met disjuncte apotheeksets) werkt
hier niet. Wat overblijft is temporeel afleiden — "de scan sluit de dienst die
openstaat" — en dat breekt zodra er één scan ontbreekt: vergeet een koerier na
dienst A uit te scannen, dan claimt de volgende stallingscan beide diensten en is
niet meer af te leiden welke.

Dit project heeft die les al twee keer geleerd: reconstructie achteraf leverde de
`disputed`-categorie `meerdere_diensten_zelfde_dag` op, en `timing_reliable`
bestaat juist omdat retroactief opschonen niet kan en vooruit labelen wel. De app
weet op het scanmoment welke dienst loopt; dan is dat ook de plek om het vast te
leggen.

## 3. Herkomst per veld, niet per rij via `status`

Start en eind krijgen elk een eigen herkomstmarkering — gemeten of opgave.

**Waarom:** `shift_time_reports.status` is één kolom voor de hele rij en kan niet
uitdrukken "eind is een opgave, start is gemeten". Zonder markering per eindpunt is
achteraf niet meer te zien welke uren gemeten waren en welke opgegeven. Dat is
precies het onderscheid waar de hele fase-3-opzet op rust; zonder dat verdwijnt het
binnen een half jaar uit de data en is het niet te reconstrueren.

## 4. Twee gescheiden toelichtingsvelden

Eén veld voor een afwijkende eindtijd, één voor "ik was eerder aan het werk".

**Waarom:** het zijn twee verschillende vragen met verschillende gevolgen. "Waarom
wijkt je eindtijd af" is een correctie op een meting (QR vergeten, telefoon leeg).
"Wat deed je vóór de apotheek" beschrijft werk waarvan geen enkele meting bestaat
en gaat altijd naar de planner. Die twee in één vrij tekstveld (`courier_comment`)
proppen maakt ze achteraf niet meer uit elkaar te houden en ondermijnt de
beoordelingsroute uit beslissing 5.

## 5. De bevestigingspagina is asymmetrisch

Start en eind zijn geen gelijkwaardige velden.

- **Eindtijd** — normaal correctiepad. Bewerkbaar veld, verplichte toelichting bij
  afwijking. Er zijn echte, legitieme redenen om af te wijken.
- **Starttijd** — wordt als vaststaand gepresenteerd. Géén bewerkbaar veld naast de
  eindtijd. Eén uitzonderingspad: de koerier deed vóór de apotheek al werk
  (bijvoorbeeld ergens een pakje ophalen). Dat valt buiten elke scan. Het wordt
  aangeboden als aparte, bewuste optie ("ik was eerder aan het werk") die vraagt om
  een vroegere starttijd én een verplichte toelichting: wat deed je, en vanaf
  wanneer.

Zulke meldingen gaan **altijd** naar de planner ter beoordeling, ook bij een kleine
afwijking.

**Waarom altijd:** bij de eindtijd is er een meting om een correctie tegen af te
zetten, bij vroeger begonnen werk is die er per definitie niet. Er is geen drempel
te kiezen waaronder een claim "vanzelf" aannemelijk is, want er is niets om hem
mee te vergelijken. Beoordeling door een mens is dan het enige controlemiddel.

## 6. Gatdetectie blijft — als signaal, niet als dispute

De detectie van onverklaarde gaten tussen deurscans blijft bestaan, maar levert
geen `disputed` meer op; het wordt een signaal aan de planner op de
bevestigingspagina.

**Waarom:** met twee gemeten eindpunten verandert een gat het venster niet meer —
start en eind staan vast. Maar de vraag die het gat stelde blijft staan, en wordt
zelfs urgenter: zit er in dat gemeten venster tijd die geen werk was (pauze, tweede
rit, een uur thuis)? Vroeger viel zo'n dienst uit de berekening; straks wordt hij
zonder signaal gewoon volledig uitbetaald.

**Gevolg:** de gatberekening gebruikt `afstand ÷ snelheid`, dus de
regressiesnelheid en de terugval-hiërarchie (`DEFAULT_SPEED_MPS`,
`MIN_LEG_DISTANCE_M`, `MIN_USABLE_LEGS`) blijven nodig — dit is het enige dat na
fase 3 nog kalibratie vergt. Daarmee blijft ook het kalibratiefilter op
`timing_reliable` functioneel nodig: testritten vervuilen die regressie net zo hard
als nu.

## 7. Geen offline-buffer

Scans worden niet lokaal gebufferd voor latere synchronisatie. Bereikproblemen bij
een stalling worden **fysiek** opgelost (plaatsing van de code, of de stalling
zelf).

**Waarom:** een offline-buffer voegt een tweede tijdstempel toe — scanmoment versus
synchronisatiemoment — en daarmee een hele klasse vragen over welke van de twee
telt. Bij een gemeten dienstvenster is dat precies de onduidelijkheid die je niet
wilt introduceren. Een bereikprobleem is bovendien een eigenschap van één fysieke
plek en daar ook op te lossen; software eromheen bouwen verplaatst het probleem
naar elke dienst.

## 8. `packages.createdAt` is betrouwbaar — geverifieerd

De starttijd hangt volledig aan `packages.createdAt` (de eerste inscan). Dat is het
werkelijke scanmoment: de bezorg-app kan niet offline scannen, dus er is geen
verschil tussen scannen en vastleggen.

**Waarom vastgelegd:** dit was een openstaand risico. De pagina presenteert de
starttijd als vaststaand (beslissing 5); zou `createdAt` een serverinsert-moment
zijn, dan zou een hard gepresenteerd getal zwakker onderbouwd zijn dan de eindtijd,
die straks een echte scan-gebeurtenis is. Dat is geverifieerd en van tafel — maar
het blijft de aanname waar de asymmetrie op rust, dus het hoort hier genoteerd als
iets dat opnieuw getoetst moet worden als de bezorg-app hierin verandert.

Let op: de QR vervangt alleen de **eind**kant. De startkant blijft afhankelijk van
pakketdata; die is niet overbodig geworden.

---

## Wat vervalt zodra de QR live gaat

Deze onderdelen zijn geen dood materiaal maar **bewust** vervallen: ze bestonden
alleen om een eindtijd af te leiden die voortaan gemeten wordt. Genoteerd zodat
niemand ze later opnieuw invoert of als bug aanmerkt.

| Wat | Waar | Reden dat het vervalt |
|---|---|---|
| `ROUND_MARGIN_MIN` (10 min) | `computeShiftTime.ts` (eindtijd) | De stallingscan *is* het eind; parkeren en afmelden zitten erin. |
| Berekende terugreis (`returnDistanceM`, `returnSec`) | `computeShiftTime.ts` | Wordt niet meer geschat maar gescand. |
| `DETOUR_FACTOR` (1.3) | idem, enige consument | Bestond alleen voor die terugreis. |
| Dispute `apotheek_geen_coordinaten` | `computeShiftTime.ts` | Bestond alleen omdat de terugreis apotheekcoördinaten nodig had. |
| Dispute `laatste_deurscan_geen_gps` | `computeShiftTime.ts` | Idem, voor het beginpunt van die terugreis. |

Nevengevolg: apotheek-coördinaten (`pharmacies."addressLat"/"addressLng"`, migratie
004 en het geocode-backfillscript) verliezen hun enige rol in de tijdberekening. Ze
blijven staan — voor planning en routeschatting zijn ze bruikbaar — maar dragen na
fase 3 niets meer bij aan een uitbetaling.

`MAX_WINDOW_HOURS` (12 u) blijft, maar krijgt meer gewicht. Nu wordt het eind
begrensd door de laatste deurscan; straks kan een koerier vergeten uit te scannen
en 's ochtends alsnog scannen. Deze bound is dan de guard die dat opvangt en
verdient een scherpere onderbouwing dan de huidige domein-aanname.

---

## Nog te beslissen

Niet besloten — hier expliciet genoteerd zodat het niet stilzwijgend ingevuld wordt
tijdens de bouw.

- **Legt de stallingscan GPS vast?** Zonder locatie is een QR-code een
  fotografeerbare string en van elke plek te scannen. Met GPS is te verifiëren dat
  de scan bij de stalling gebeurde. Deurscans leggen wél GPS vast
  (`deliveryEvidence.latitude/longitude`, met `(0,0)` als sentinel bij ontbrekende
  GPS).
- **Kan de scanner in de bezorg-app een niet-pakket-QR aan?** Elke tijdstempel in
  het huidige model hangt aan een pakketrij; een stallingscan hoort bij geen enkel
  pakket en heeft dus sowieso een eigen opslag nodig. Of de scanner zelf aangepast
  moet worden, is in de bezorg-app-repo te verifiëren.
- **Ontbrekende stallingscan.** Voorkeur: geen eindtijd, de koerier vult hem in bij
  de bevestiging, expliciet gemarkeerd als opgave in plaats van meting (dat is
  precies waar beslissing 3 in voorziet). Consistent met het bestaande principe in
  `computeShiftTime.ts`: bij twijfel geen getal teruggeven, want fout raden is
  duurder dan niets teruggeven.
