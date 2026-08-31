# Fase 7 — facturatie richting apotheken

Status: **gebouwd, migratie nog niet gedraaid.** Migratie 025 zet het datamodel en
de berekening neer, de schermen zitten in de app. Er wordt niets verstuurd en
niets gegenereerd: dit is een model plus een overzicht.

Fase 6 is gebouwd rond **koerier en dienst**. Dit is dezelfde werkelijkheid vanaf
de andere kant: **klant en opdracht**. De werkelijke duur komt uit de
nadeclaraties (`shift_declarations.actual_start/actual_end`); daar wordt alleen
uit gelezen. `declaration_compute()`, `declaration_overview()` en de mailketen
zijn niet aangeraakt.

---

## 1. Een naam die afwijkt van de opdracht

De opdracht spreekt van `shift_type = 'spoed'`. Die waarde bestaat niet: migratie
001 legt vier types vast — `regular`, `institution`, `other_transport`, `urgent` —
en de spoeddienst heet daar **`urgent`**. "Spoed" is het Nederlandse label in de
interface (`TYPE_STYLES.urgent.label`). In de database staat overal `urgent`.

---

## 2. De rekenregels

### Uren, naar rato — in beide richtingen

De planning legt per apotheek een aantal geplande minuten vast
(`shift_pharmacies.budgeted_minutes`). De werkelijke duur wordt over de apotheken
verdeeld naar rato van die minuten.

```
Gepland:   apotheek A 2 uur, apotheek B 2 uur   (totaal 4)
Werkelijk: 5 uur
Resultaat: A 2,5 uur, B 2,5 uur
```

Dat werkt beide kanten op: is de koerier in 3 uur klaar, dan krijgt elke apotheek
1,5 uur. **Geen ondergrens en geen plafond** — anders zou de ene richting wel
doortellen en de andere niet, en dat is geen verdeling maar een korting die
alleen ten gunste van één partij uitvalt. Bij één apotheek in de dienst gaat de
volledige duur daarheen.

### Starttarief — niet verdelen

Elke apotheek in de dienst krijgt een **volledig** starttarief, tegen haar eigen
tarief. Bij twee apotheken dus twee keer. Voor de apotheek is het een aparte
opdracht: of de koerier er daarna nog ergens langsging is haar zaak niet.

### Reiskosten — naar rato

De vergoeding uit de declaratie (`computed_reimbursable_km` × het tarief dat aan
die declaratie hangt) volgt dezelfde verhouding als de uren. Alleen als de
koerier ook daadwerkelijk declareert: het is altijd
`claims_travel` × `computed_reimbursable_km`, nooit dat tweede getal alleen.

### Spoed — alleen het afgesproken bedrag

Bij `urgent` telt uitsluitend `shifts.urgent_amount`: geen uren, geen
starttarief, geen reiskosten. Dat bedrag wordt telefonisch afgesproken en komt
dus niet uit een tarieventabel; er hoort een toelichting bij (`urgent_note`) zodat
later navraag mogelijk is.

De koerier krijgt zijn uren gewoon uitbetaald via de declaratieketen. Dat staat
hier los van, en juist daarom staan de uren wél in de factuurregel: dan is
zichtbaar waar het bedrag tegenover staat.

---

## 3. Wat er ontbreekt wordt gemarkeerd, niet aangenomen

Zelfde lijn als `declaration_compute()` in fase 6: de regel wordt berekend met
wat er is, en krijgt `incomplete` plus een leesbare `reason`.

| Situatie | Wat er gebeurt | Melding |
|---|---|---|
| geen ingevulde declaratie | geplande uren gefactureerd | "geen ingevulde declaratie; geplande uren gefactureerd" |
| geen `budgeted_minutes` bij meerdere apotheken | gelijk verdeeld | "geen geplande minuten vastgelegd; gelijk verdeeld over N apotheken" |
| geen tarief op die datum | geen bedrag (`line_total` is NULL) | "geen tarief voor deze apotheek op …" |
| werkelijk wijkt ver af van gepland | niets — de berekening blijft staan | "werkelijke duur wijkt N% af van gepland" |
| spoed zonder bedrag | geen bedrag | "spoedbedrag nog niet ingevuld" |

De laatste twee verdienen toelichting.

**De afwijking is een signaal, geen afkeuring.** Bij één apotheek in de dienst
gaat een uitloop volledig naar die klant, en een factuur die verdubbelt door een
invoerfout wil je zien vóór je hem verstuurt. De grens staat in
`invoice_settings.deviation_pct` (standaard 25) en is dus instelbaar.

**Bij spoed vervallen de uren-meldingen.** Geen declaratie, een onbekende
verhouding, een afwijking van de planning — geen daarvan raakt het factuurbedrag
bij spoed. Een markering op een regel die gewoon klopt leert de planner om
markeringen te negeren, en dan is de markering elders ook niets meer waard.

**Een regel zonder tarief telt nergens in mee.** `line_total` is dan NULL, en het
overzicht telt die regels apart op ("N regels hebben géén bedrag"), zodat een
subtotaal nooit stilzwijgend te laag is.

---

## 4. Wat er in de database bij komt

| Object | Waarvoor |
|---|---|
| `shift_pharmacies.budgeted_minutes` | de ontbrekende schakel: hoeveel tijd elke apotheek in een gedeelde dienst krijgt |
| `pharmacy_rates` | uurtarief en starttarief per apotheek, met `effective_from` |
| `shifts.urgent_amount` / `urgent_note` | het telefonisch afgesproken spoedbedrag |
| `invoice_settings` | de afwijkingsgrens |
| `pharmacy_rate_on()` | het tarief dat gold op een datum — zelfde vorm als `reimbursement_rate_on()` |
| `invoice_lines()` | de berekening |
| `set_pharmacy_rate()` / `delete_pharmacy_rate()` | tariefbeheer |

Alle nieuwe kolommen zijn **nullable en additief**: `shifts`, `shift_pharmacies`
en `user_profiles` zijn gedeeld met AIrouteplanner en de bezorg-app. De trigger
op de spoedvelden doet niets zolang die velden leeg zijn, dus voor die apps
verandert er niets.

Er worden **geen starttarieven ingevuld** bij de installatie. Anders dan bij de
kilometervergoeding is er geen landelijk getal om op terug te vallen, en een
verzonnen tarief dat plausibel oogt merk je pas als de factuur de deur uit is.
Geen rij = geen tarief = zichtbaar onvolledige regel.

### Concepten tellen niet mee

`invoice_lines()` slaat `status = 'draft'` over: een concept is niet bevestigd en
dus geen opdracht. Alles wat wél bevestigd is telt, ongeacht of de koerier al
ingevuld heeft.

---

## 5. Geen aannames over een exportformaat

De koppeling naar een boekhoudpakket is nog niet bepaald. `invoice_lines()` is
daarom een **berekening en geen bestandsgenerator**: het levert rijen met
bedragen, en wat daarmee gebeurt is aan de aanroeper. Het overzichtsscherm telt
ze alleen op.

---

## 6. Uitrollen

1. **Migratie 025** draaien (dry-run met `ROLLBACK;` mag eerst), daarna
   `supabase/tests/025_pharmacy_invoicing_test.sql`.
2. **Tarieven invoeren** per apotheek, in *Apotheken → Tarieven*. Zonder tarief
   blijft elke regel van die apotheek zonder bedrag staan. De verificatiequery
   onderaan de migratie geeft de lijst apotheken zonder tarief.
3. **Geplande minuten** gaan vanaf nu mee in *Dienst toevoegen* en *Dienst
   bewerken*, per aangevinkte apotheek. Bestaande diensten hebben ze niet; die
   worden gelijk verdeeld en gemarkeerd. De tweede verificatiequery toont de
   gedeelde diensten waar dat speelt.
4. **Facturatie** in de kop van de app: apotheek + periode → de regels met
   subtotalen.

---

## Nog te beslissen

* **Boekhoudkoppeling.** Zie punt 5.
* **Wie de spoedbedragen invoert en wanneer.** Nu kan het bij het inplannen en bij
  het bewerken; er is geen moment waarop het systeem erom vraagt.
* **Terugwerkende kracht bij een tariefwijziging.** Een nieuwe `effective_from`
  laat oude regels ongemoeid — dat is de bedoeling. Wat er moet gebeuren als een
  tarief met terugwerkende kracht wijzigt ná het versturen van een factuur, is
  niet belegd; die factuur bestaat immers alleen buiten dit systeem.
