# Parameters van het rekenmodel diensttijd — herkomst & kalibratie

Elk getal in de tijdberekening staat als benoemde constante in
[`constants.ts`](./constants.ts) en wordt hieronder verantwoord. **Peildatum: nog
géén enkele waarde is uit Greenspeed-data afgeleid** — het zijn plaatshouders,
vuistregels of domein-aannames. Ze moeten geijkt worden zodra er genoeg
*bevestigde* diensten zijn (zie de kalibratie-drempel: ~50 bevestigingen; de
diensten­laag is nu nog testdata).

De berekende tijd is een **voorstel** dat de koerier corrigeert; die correcties
(`confirmed_*` vs `computed_*` in `shift_time_reports`) zijn de belangrijkste
ijkbron.

| Parameter | Constante | Waarde | Herkomst | Bijstellen met |
|---|---|---|---|---|
| Voormarge | `PRE_MARGIN_MIN` | 15 min | Plaatshouder, niet uit data | Mediaan van (bevestigde starttijd − eerste inscan) |
| Afrondmarge | `ROUND_MARGIN_MIN` | 10 min | Plaatshouder, niet uit data | Mediaan van (bevestigde eindtijd − (laatste deurscan + terugreis)) |
| Omwegfactor | `DETOUR_FACTOR` | 1.3 | Gangbare stadsvuistregel | Werkelijke wegafstand (Routes API) ÷ hemelsbreed, over echte trajecten |
| Min. trajectlengte | `MIN_LEG_DISTANCE_M` | 300 m | Heuristiek (GPS-ruis) | Regressie-residuen vs trajectlengte |
| Min. trajecten | `MIN_USABLE_LEGS` | 5 | Statistische vuistregel | Stabiliteit helling (R²/CI) vs aantal trajecten |
| Max. venster | `MAX_WINDOW_HOURS` | 12 u | Domein-aanname (sanity bound) | Verdeling van echte dienstduren |
| Gat-drempel | `GAP_THRESHOLD_MIN` | 45 min | Heuristiek (pauze/2e rit) | Verdeling (gat − verwachte reistijd) tussen stops |
| Terugval-snelheid fiets | `DEFAULT_SPEED_MPS.bike` | 4.0 m/s (~14 km/u) | **Plaatshouder**, niet uit data | Gemeten per-dienst-snelheden, geaggregeerd apotheek→groep→landelijk |
| Terugval-snelheid auto | `DEFAULT_SPEED_MPS.car` | 7.0 m/s (~25 km/u) | **Plaatshouder**, niet uit data | Idem |
| GPS-nulmarge | `GPS_ZERO_EPS` | 0.0001 | Technische sentinel (toestel schrijft (0,0)) | n.v.t. — geen kalibratie-parameter |

## Gevoeligheid (gemeten, 348 bezorgingen)

De terugval-snelheid raakt **alleen de terugreis** (laatste deur → apotheek), niet
de gemeten bezorgtijden of de marges, en alleen bij diensten zonder eigen
(measured) snelheid. Gemeten over 348 bezorgingen ná uitsluiten van het testaccount
(90ae1c75, 211 bezorgingen) en seed ph-1 (161); geen datumgrens. Bij een fout 4→3 m/s:

| deur→apotheek | median 1,20 km | p75 1,94 km | p90 3,93 km | max 16,9 km |
|---|---|---|---|---|
| extra eindtijd | +2,2 min | +3,5 min | +7,1 min | |

Klein over de hele linie (enkele minuten, ook in de p90). De eerdere "materiële
staart" (p90 9,3 km, +16,7 min) bleek grotendeels het testaccount — precies waarom
vermenging vooruit gelabeld moet worden i.p.v. op afstand geschat.

## Data-hygiëne (geen parameter)

`SEED_EXCLUDED_PHARMACY_IDS` (`constants.ts`) weert seed-/testapotheken uit alle
berekening en kalibratie — nu `ph-1` ("Test Apotheek", 386 pakketten, waarvan 384
aan courierIds zonder `user_profile`). Expliciet, niet leunend op toevallig
ontbrekende coördinaten. Verweesde-courier-pakketten (courierId zonder
`user_profile`; in totaal 384 over Test/Mijn Apotheek) worden sowieso nooit aan een
dienst gekoppeld omdat `shifts.courier_id` een FK naar `user_profiles` is.

**Gedeelde dag (meerdere diensten, zelfde koerier):** als de apotheeksets van die
diensten disjunct zijn, splitst de kalibratie de pakketten op de apotheek(en) van
elke dienst en legt dat vast in `calc_details.attribution` (geen plaatshouder —
puur op basis van `pharmacyId`). Overlappen de apotheeksets, dan kan de toewijzing
niet eenduidig en gaat de dienst naar `disputed:meerdere_diensten_zelfde_dag`.

## Werkwijze

Wijzig een waarde alléén in `constants.ts`, verhoog `MODEL_VERSION`, en noteer de
onderbouwing in de tabel hierboven. Zo blijft elke opgeslagen `calc_details`
herleidbaar naar de modelversie waarmee hij berekend is.
