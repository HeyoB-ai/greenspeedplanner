// ── Kalibreerbare parameters van het rekenmodel voor de diensttijd ──────────
// Alle marges, drempels en factoren staan hier bij elkaar, zodat ze bij te
// stellen zijn zónder de logica in computeShiftTime.ts aan te raken. Verhoog
// MODEL_VERSION bij elke inhoudelijke wijziging; die versie gaat mee in
// calc_details zodat elke opgeslagen uitkomst herleidbaar blijft.

export const MODEL_VERSION = 'v1';

// Voormarge: tijd vóór de eerste inscan (aankomst, klaarmaken, inpakken aan de
// balie). Nog niet empirisch geijkt — startwaarde, herzien na de kalibratie.
export const PRE_MARGIN_MIN = 15;

// Afrondmarge: tijd ná terugkomst bij de apotheek (parkeren, afmelden).
export const ROUND_MARGIN_MIN = 10;

// Omwegfactor: hemelsbrede afstand → werkelijke wegafstand. 1.3 is een gangbare
// stadswaarde; herzien zodra we routeafstanden tegen hemelsbreed kunnen ijken.
export const DETOUR_FACTOR = 1.3;

// Trajecten korter dan dit (meter) geven onbetrouwbare snelheden (GPS-ruis,
// twee deuren in hetzelfde flatgebouw) en tellen niet mee in de regressie.
export const MIN_LEG_DISTANCE_M = 300;

// Minder dan zoveel bruikbare trajecten → geen eigen snelheid, val terug op de
// hiërarchie (apotheek → groep → landelijk).
export const MIN_USABLE_LEGS = 5;

// Venster langer dan dit (uur) is onwaarschijnlijk → disputed i.p.v. voorstel.
export const MAX_WINDOW_HOURS = 12;

// Een gat tussen twee opeenvolgende deurscans dat na aftrek van de verwachte
// reistijd (afstand ÷ snelheid) en overdracht nog groter is dan dit (minuten),
// duidt op een pauze of tweede rit → disputed. Het gat wordt NOOIT automatisch
// afgetrokken; het wordt zichtbaar gemaakt in calc_details.
export const GAP_THRESHOLD_MIN = 45;

// Landelijke terugval-snelheid per vervoermiddel (m/s), als er te weinig eigen
// trajecten zijn. bike ≈ 14 km/u, car ≈ 25 km/u (stads-/dorpsgemiddelde incl.
// stoplichten). Startwaarden — de kalibratie levert betere per-apotheek/groep.
export const DEFAULT_SPEED_MPS: Record<'bike' | 'car', number> = {
  bike: 4.0,
  car: 7.0,
};

// Het toestel schrijft (0,0) als de GPS niet beschikbaar was. Zulke punten zijn
// GEEN locatie en tellen niet mee. Alles binnen deze marge van (0,0) = ontbrekend.
export const GPS_ZERO_EPS = 0.0001;
