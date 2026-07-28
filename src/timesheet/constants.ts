// ── Kalibreerbare parameters van het rekenmodel voor de diensttijd ──────────
// Alle marges, drempels en factoren staan hier bij elkaar, zodat ze bij te
// stellen zijn zónder de logica in computeShiftTime.ts aan te raken. Verhoog
// MODEL_VERSION bij elke inhoudelijke wijziging; die versie gaat mee in
// calc_details zodat elke opgeslagen uitkomst herleidbaar blijft.
//
// LET OP — GEEN GETAL ZONDER HERKOMST. Op dit moment komt GEEN van deze waarden
// uit Greenspeed-data; het zijn plaatshouders, vuistregels of domein-aannames.
// Bij elke constante staat: [HERKOMST] waar de waarde vandaan komt en
// [BIJSTELLEN MET] waarmee hij geijkt moet worden zodra er data is. Een compleet
// overzicht staat in src/timesheet/PARAMETERS.md.

export const MODEL_VERSION = 'v1'; // versielabel (geen parameter); ophogen bij elke inhoudelijke wijziging hieronder

// Voormarge (min): tijd vóór de eerste inscan — aankomst, uitpakken, klaarmaken
// aan de balie.
// [HERKOMST]      plaatshouder, niet uit data.
// [BIJSTELLEN MET] mediaan van (door koerier bevestigde starttijd − eerste inscan),
//                  zodra bevestigingen binnenkomen (Fase 3).
export const PRE_MARGIN_MIN = 15;

// Afrondmarge (min): tijd ná terugkomst bij de apotheek — parkeren, afmelden.
// [HERKOMST]      plaatshouder, niet uit data.
// [BIJSTELLEN MET] mediaan van (bevestigde eindtijd − (laatste deurscan + berekende
//                  terugreis)), zodra bevestigingen binnenkomen (Fase 3).
export const ROUND_MARGIN_MIN = 10;

// Omwegfactor: hemelsbrede afstand → werkelijke wegafstand.
// [HERKOMST]      gangbare stadsvuistregel (~1.3), niet uit deze data.
// [BIJSTELLEN MET] verhouding werkelijke wegafstand (Google Routes API) ÷ hemelsbrede
//                  afstand, gemeten over echte trajecten.
export const DETOUR_FACTOR = 1.3;

// Minimale trajectlengte (m) die meetelt in de snelheidsregressie. Kortere
// trajecten geven ruis (GPS-onnauwkeurigheid, twee deuren in één flat).
// [HERKOMST]      heuristiek, niet uit data.
// [BIJSTELLEN MET] regressie-residuen uitgezet tegen trajectlengte — zoek de lengte
//                  waaronder korte trajecten de fit vertroebelen.
export const MIN_LEG_DISTANCE_M = 300;

// Minimum aantal bruikbare trajecten voor een eigen (measured) snelheid; minder
// → terugval op de hiërarchie (apotheek → groep → landelijk).
// [HERKOMST]      statistische vuistregel voor een stabiele lineaire fit.
// [BIJSTELLEN MET] stabiliteit van de helling (R²/betrouwbaarheidsinterval) als
//                  functie van het aantal trajecten.
export const MIN_USABLE_LEGS = 5;

// Maximaal aannemelijk dienstvenster (uur); langer → disputed i.p.v. voorstel.
// [HERKOMST]      domein-aanname (sanity bound), niet uit data.
// [BIJSTELLEN MET] verdeling van echte dienstduren (hoort ruim onder 12 u te liggen).
export const MAX_WINDOW_HOURS = 12;

// Drempel (min) voor een "onverklaard gat" tussen twee deurscans: het deel van
// het gat dat overblijft na aftrek van verwachte reistijd (afstand ÷ snelheid)
// en overdracht. Groter → disputed (pauze/tweede rit). Wordt NOOIT automatisch
// afgetrokken, alleen zichtbaar gemaakt in calc_details.
// [HERKOMST]      heuristiek, niet uit data.
// [BIJSTELLEN MET] verdeling van (gat − verwachte reistijd) tussen stops; kies de
//                  natuurlijke knik tussen "normaal" en "pauze".
export const GAP_THRESHOLD_MIN = 45;

// Landelijke terugval-snelheid per vervoermiddel (m/s), gebruikt als er te
// weinig eigen trajecten zijn. bike 4.0 ≈ 14 km/u, car 7.0 ≈ 25 km/u.
// [HERKOMST]      PLAATSHOUDER — mijn schatting van stads-/dorpsgemiddelden, NIET
//                 uit Greenspeed-data.
// [BIJSTELLEN MET] gemeten per-dienst-regressiesnelheden, geaggregeerd per
//                  apotheek → groep → landelijk (de terugval-hiërarchie zelf).
export const DEFAULT_SPEED_MPS: Record<'bike' | 'car', number> = {
  bike: 4.0,
  car: 7.0,
};

// Het toestel schrijft (0,0) als de GPS niet beschikbaar was. Zulke punten zijn
// GEEN locatie en tellen niet mee. Alles binnen deze marge van (0,0) = ontbrekend.
// [HERKOMST]      technische sentinel — geverifieerd gedrag van de bezorg-app
//                 (NotHomeSheet.tsx valt terug op {latitude:0, longitude:0}).
// [BIJSTELLEN MET] n.v.t. — geen kalibratie-parameter; alleen wijzigen als het
//                  toestel-gedrag verandert.
export const GPS_ZERO_EPS = 0.0001;

// ── Data-hygiëne (GEEN model-parameter) ─────────────────────────────────────
// Apotheken die uit ALLE tijdberekening én kalibratie geweerd worden omdat het
// seed-/testdata is. Expliciet uitsluiten — NIET vertrouwen op het toeval dat
// zo'n apotheek (nu) geen coördinaten heeft.
//   ph-1 = "Test Apotheek": 386 pakketten (grootste post in de tabel), waarvan
//   384 aan courierIds die bij geen enkel user_profile horen (seed-data).
// Verweesde-courier-pakketten worden sowieso nooit aan een dienst gekoppeld
// (shifts.courier_id is FK naar user_profiles), dus die vergen geen aparte
// filter; deze lijst is de expliciete apotheek-uitsluiting.
export const SEED_EXCLUDED_PHARMACY_IDS: string[] = ['ph-1'];
