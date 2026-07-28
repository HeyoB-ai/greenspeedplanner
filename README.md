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
