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

## Gevoeligheid (gemeten, 522 echte bezorgingen)

De terugval-snelheid raakt **alleen de terugreis** (laatste deur → apotheek), niet
de gemeten bezorgtijden of de marges, en alleen bij diensten zonder eigen
(measured) snelheid. Bij een fout van 4→3 m/s:

| deur→apotheek | median 1,28 km | p75 2,49 km | p90 9,25 km |
|---|---|---|---|
| extra eindtijd | +2,3 min | +4,5 min | +16,7 min |

Klein op een typische stadsdienst; materieel in de staart (lange laatste benen).

## Werkwijze

Wijzig een waarde alléén in `constants.ts`, verhoog `MODEL_VERSION`, en noteer de
onderbouwing in de tabel hierboven. Zo blijft elke opgeslagen `calc_details`
herleidbaar naar de modelversie waarmee hij berekend is.
