import { useEffect, useMemo, useRef, useState } from 'react';
import { AlertTriangle, Calculator, Check, Home, ListChecks, X } from 'lucide-react';
import { CourierDistance, CourierHome, Pharmacy } from '../types';
import { getPharmacies } from './plannerService';
import {
  DistanceRun, FALLBACK_TEXT, SOURCE_LABELS, computeDistances, getCourierAddress, getCourierHomes,
  getCourierPharmacyIds, getDistances, setCourierAddress, setDistanceManual, setHomePharmacy,
} from './addressService';

interface Props {
  onClose: () => void;
}

// Eén regel uit de afsluiting van "Alle afstanden berekenen".
interface BulkOutcome {
  courierName: string;
  error?: string;        // de berekening mislukte
  skipped?: string[];    // gelukt, maar apotheken zonder coördinaten overgeslagen
  estimated?: string[];  // gelukt, maar Google gaf voor deze apotheken geen route
  reason?: string | null;
}

// De apotheken waarvoor alleen een schatting kwam. Oranje en voluit, want een
// schatting gaat net zo goed de vergoeding in als een route — alleen weet
// niemand of hij klopt.
function estimatedNames(run: DistanceRun): string[] {
  return run.distances.filter((d) => d.source === 'fallback').map((d) => d.pharmacy_name);
}

function kmText(km: number): string {
  return `${km.toFixed(1).replace('.', ',')} km`;
}

// Wat deze berekening werkelijk wegschreef: de handmatige bleven staan.
function written(run: DistanceRun): number {
  return run.distances.filter((d) => !d.kept_manual).length;
}

// Per apotheek met een handmatige afstand: wat Google ervan maakte.
function computedFromRun(run: DistanceRun): Record<string, { km: number; source: string }> {
  return Object.fromEntries(run.distances
    .filter((d) => d.kept_manual && d.computed_km != null)
    .map((d) => [d.pharmacy_id, { km: d.computed_km!, source: d.computed_source ?? 'route' }]));
}

// Beheerscherm voor de standplaats en de afstanden per koerier (migratie 018).
//
// Het woonadres wordt sinds 7 oktober 2026 BEWAARD (migratie 057), alleen
// zichtbaar voor planners. Het staat in het invoerveld zodra een koerier wordt
// opengeklapt, zodat een planner kan zien wat er gebruikt wordt en een tikfout
// kan verbeteren. Berekenen legt een gewijzigd adres eerst vast en laat de Edge
// Function daarna met het bewaarde rekenen — zo kan wat er in de database staat
// nooit afwijken van waarmee de afstanden zijn berekend.
export default function CourierAddresses({ onClose }: Props) {
  const [homes, setHomes] = useState<CourierHome[]>([]);
  const [pharmacies, setPharmacies] = useState<Pharmacy[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  const [openId, setOpenId] = useState<string | null>(null);
  // Welke koerier er NU open is, ook binnen een lopende await. Klapt de planner
  // snel een andere open, dan mag het adres van de vorige niet alsnog in het
  // veld van de nieuwe terechtkomen.
  const openRef = useRef<string | null>(null);
  const [address, setAddress] = useState('');
  // Wat er bewaard staat, om te weten of het veld gewijzigd is.
  const [savedAddress, setSavedAddress] = useState('');
  const [addressLoading, setAddressLoading] = useState(false);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [rowError, setRowError] = useState<Record<string, string>>({});
  const [run, setRun] = useState<DistanceRun | null>(null);
  const [existing, setExisting] = useState<CourierDistance[]>([]);
  const [manual, setManual] = useState<Record<string, string>>({});
  // De apotheken van de open koerier, los van wat er al aan afstanden staat: ook
  // een apotheek zonder afstand en zonder coördinaten moet een invoerveld hebben.
  const [courierPharmacyIds, setCourierPharmacyIds] = useState<string[]>([]);
  // Wat Google berekende voor apotheken met een handmatige afstand, uit de
  // laatste berekening. Om het verschil met de ANWB naast elkaar te zetten.
  const [computedForManual, setComputedForManual] = useState<Record<string, { km: number; source: string }>>({});

  const [bulk, setBulk] = useState<{ at: number; total: number; current: string } | null>(null);
  const [bulkOutcome, setBulkOutcome] = useState<{ total: number; keptManual: number; outcomes: BulkOutcome[] } | null>(null);
  const bulkBusy = bulk !== null;

  async function reload() {
    setLoading(true);
    try {
      const [hs, ps] = await Promise.all([getCourierHomes(), getPharmacies()]);
      setHomes(hs);
      setPharmacies(ps);
      setError('');
    } catch (e: any) {
      setError(e?.message ?? 'Laden mislukt.');
    } finally {
      setLoading(false);
    }
  }
  useEffect(() => { reload(); }, []);

  const pharmacyName = useMemo(
    () => new Map(pharmacies.map((p) => [p.id, p.name])), [pharmacies],
  );

  const withoutHome = useMemo(() => homes.filter((h) => !h.homePharmacyId), [homes]);
  const withAddress = useMemo(() => homes.filter((h) => h.hasAddress), [homes]);

  // Alle apotheken van de open koerier: gekoppeld, standplaats, en alles waar al
  // een afstand voor staat. Dat laatste ook als de koppeling inmiddels weg is —
  // anders verdwijnt een bestaande afstand uit beeld terwijl hij nog meetelt.
  function pharmacyIdsFor(h: CourierHome): string[] {
    const ids = new Set<string>(courierPharmacyIds);
    if (h.homePharmacyId) ids.add(h.homePharmacyId);
    existing.forEach((d) => ids.add(d.pharmacyId));
    return [...ids].sort((a, b) => (pharmacyName.get(a) ?? a).localeCompare(pharmacyName.get(b) ?? b, 'nl'));
  }

  async function openCourier(courierId: string) {
    if (openId === courierId) { setOpenId(null); openRef.current = null; return; }
    setOpenId(courierId);
    openRef.current = courierId;
    setAddress('');
    setSavedAddress('');
    setRun(null);
    setManual({});
    setComputedForManual({});
    setCourierPharmacyIds([]);
    setRowError((m) => ({ ...m, [courierId]: '' }));
    setAddressLoading(true);

    const [dist, adr, phs] = await Promise.allSettled([
      getDistances(courierId), getCourierAddress(courierId), getCourierPharmacyIds(courierId),
    ]);
    if (openRef.current !== courierId) return;

    setExisting(dist.status === 'fulfilled' ? dist.value : []);
    setCourierPharmacyIds(phs.status === 'fulfilled' ? phs.value : []);
    if (adr.status === 'fulfilled') {
      setAddress(adr.value ?? '');
      setSavedAddress(adr.value ?? '');
    } else {
      setRowError((m) => ({ ...m, [courierId]: adr.reason?.message ?? 'Het adres kon niet opgehaald worden.' }));
    }
    setAddressLoading(false);
  }

  async function saveHome(courierId: string, pharmacyId: string) {
    setBusyId(courierId);
    setRowError((m) => ({ ...m, [courierId]: '' }));
    try {
      await setHomePharmacy(courierId, pharmacyId || null);
      await reload();
    } catch (e: any) {
      setRowError((m) => ({ ...m, [courierId]: e?.message ?? 'Opslaan mislukt.' }));
    } finally {
      setBusyId(null);
    }
  }

  async function calculate(courierId: string) {
    const value = address.trim();
    if (value.length < 6) {
      setRowError((m) => ({ ...m, [courierId]: 'Vul straat, huisnummer, postcode en plaats in.' }));
      return;
    }
    setBusyId(courierId);
    setRowError((m) => ({ ...m, [courierId]: '' }));
    try {
      // Eerst vastleggen, dan rekenen met wat er bewaard staat. Andersom kan een
      // berekening slagen met een adres dat daarna niet opgeslagen blijkt — en
      // dan rekent de volgende herberekening met het oude.
      if (value !== savedAddress.trim()) {
        await setCourierAddress(courierId, value);
        setSavedAddress(value);
        setAddress(value);
      }
      const result = await computeDistances(courierId);
      setRun(result);
      setComputedForManual(computedFromRun(result));
      setExisting(await getDistances(courierId));
      await reload();
    } catch (e: any) {
      setRowError((m) => ({ ...m, [courierId]: e?.message ?? 'Berekenen mislukt.' }));
    } finally {
      setBusyId(null);
    }
  }

  // Een handmatige afstand terugzetten naar de berekende. Via de Edge Function
  // en niet via een eigen RPC: die schrijft de berekende waarde er meteen
  // overheen, dus er is geen tussenstand waarin de apotheek zonder afstand staat
  // en de declaratie onvolledig wordt. Heeft de apotheek geen coördinaten, dan is
  // er geen berekende waarde, en blijft de handmatige staan — de functie zegt dat.
  async function resetManual(courierId: string, pharmacyId: string) {
    setBusyId(courierId);
    setRowError((m) => ({ ...m, [courierId]: '' }));
    try {
      const result = await computeDistances(courierId, undefined, [pharmacyId]);
      setRun(result);
      setComputedForManual(computedFromRun(result));
      setExisting(await getDistances(courierId));
      await reload();
    } catch (e: any) {
      setRowError((m) => ({ ...m, [courierId]: e?.message ?? 'Terugzetten mislukt.' }));
    } finally {
      setBusyId(null);
    }
  }

  // Alle koeriers met een bewaard adres, één voor één. Niet parallel: de
  // geocoder en de Routes API hebben limieten per seconde, en zestien tegelijk
  // levert zestien halve fouten op in plaats van één nette rij.
  //
  // Een fout bij één koerier stopt de rest niet. Wie na een nieuwe apotheek alle
  // afstanden ververst wil weten bij wie het misging, niet dat het bij de derde
  // ophield.
  async function calculateAll() {
    const targets = withAddress;
    if (targets.length === 0) return;
    setBulkOutcome(null);
    const outcomes: BulkOutcome[] = [];
    let keptManual = 0;

    for (let i = 0; i < targets.length; i++) {
      const h = targets[i];
      setBulk({ at: i + 1, total: targets.length, current: h.courierName });
      try {
        const result = await computeDistances(h.courierId);
        keptManual += result.keptManual;
        const estimated = estimatedNames(result);
        if (result.skipped.length > 0 || estimated.length > 0) {
          outcomes.push({
            courierName: h.courierName,
            skipped: result.skipped.length > 0 ? result.skipped.map((s) => s.name) : undefined,
            estimated: estimated.length > 0 ? estimated : undefined,
            reason: result.routeError,
          });
        }
      } catch (e: any) {
        outcomes.push({ courierName: h.courierName, error: e?.message ?? 'Berekenen mislukt.' });
      }
    }

    setBulk(null);
    setBulkOutcome({ total: targets.length, keptManual, outcomes });
    await reload();
    if (openRef.current) {
      const id = openRef.current;
      getDistances(id).then((d) => { if (openRef.current === id) setExisting(d); }).catch(() => {});
    }
  }

  async function saveManual(courierId: string, pharmacyId: string) {
    const km = Number((manual[pharmacyId] ?? '').replace(',', '.'));
    if (!Number.isFinite(km) || km < 0) {
      setRowError((m) => ({ ...m, [courierId]: 'Vul een geldig aantal kilometers in.' }));
      return;
    }
    setBusyId(courierId);
    setRowError((m) => ({ ...m, [courierId]: '' }));
    try {
      await setDistanceManual(courierId, pharmacyId, km);
      setManual((m) => ({ ...m, [pharmacyId]: '' }));
      setExisting(await getDistances(courierId));
      await reload();
    } catch (e: any) {
      setRowError((m) => ({ ...m, [courierId]: e?.message ?? 'Opslaan mislukt.' }));
    } finally {
      setBusyId(null);
    }
  }

  const failed = bulkOutcome?.outcomes.filter((o) => o.error) ?? [];
  const estimatedOut = bulkOutcome?.outcomes.filter((o) => o.estimated) ?? [];
  const skippedOut = bulkOutcome?.outcomes.filter((o) => o.skipped) ?? [];

  return (
    <div className="fixed inset-0 z-50 bg-black/40 flex items-start justify-center p-4 overflow-y-auto" onClick={onClose}>
      <div className="bg-white rounded-xl shadow-lg w-full max-w-3xl my-8" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between px-5 py-3 border-b border-slate-200">
          <h2 className="font-semibold text-slate-800 inline-flex items-center gap-2">
            <Home size={16} className="text-green-700" /> Standplaats en afstanden
          </h2>
          <button onClick={onClose} className="text-slate-400 hover:text-slate-700"><X size={18} /></button>
        </div>

        <div className="p-5 space-y-4">
          {error && <p className="text-sm text-red-600">{error}</p>}
          {loading && <p className="text-sm text-slate-500">Laden…</p>}

          <p className="text-sm text-slate-600">
            De standplaats bepaalt de reiskostenregel: naar de eigen standplaats geldt de drempel,
            naar een andere apotheek wordt de volle afstand vergoed. Het woonadres wordt{' '}
            <strong>bewaard</strong> zodat afstanden opnieuw berekend kunnen worden zonder het opnieuw
            in te typen — alleen planners kunnen het zien.
          </p>

          <div className="flex flex-wrap items-center gap-3">
            <button
              onClick={calculateAll} disabled={bulkBusy || busyId !== null || withAddress.length === 0}
              title={withAddress.length === 0 ? 'Nog van geen enkele koerier een adres bewaard' : undefined}
              className="inline-flex items-center gap-1.5 px-3 py-1.5 text-sm bg-green-600 hover:bg-green-700 disabled:opacity-60 text-white rounded-lg font-medium"
            >
              <ListChecks size={15} /> Alle afstanden berekenen
            </button>
            <span className="text-sm text-slate-500">
              {bulk
                ? `${bulk.at} van ${bulk.total} — ${bulk.current}…`
                : `${withAddress.length} van ${homes.length} koeriers hebben een bewaard adres`}
            </span>
          </div>

          {bulkOutcome && (
            <div className={`rounded-lg border text-sm p-3 space-y-1 ${
              failed.length > 0 || estimatedOut.length > 0
                ? 'bg-amber-50 border-amber-200 text-amber-800'
                : 'bg-green-50 border-green-200 text-green-800'}`}>
              <p className="font-medium inline-flex items-center gap-1">
                {failed.length === 0 && estimatedOut.length === 0 && <Check size={15} />}
                {bulkOutcome.total - failed.length} van {bulkOutcome.total} koeriers berekend
                {failed.length > 0 && `, bij ${failed.length} ging het mis`}
                {estimatedOut.length > 0 && `, bij ${estimatedOut.length} alleen geschat`}
              </p>
              {bulkOutcome.keptManual > 0 && (
                <p className="text-slate-700">
                  {bulkOutcome.keptManual === 1 ? 'Eén handmatige afstand is' : `${bulkOutcome.keptManual} handmatige afstanden zijn`}{' '}
                  blijven staan — de ANWB is leidend.
                </p>
              )}
              {failed.map((o) => (
                <p key={`f-${o.courierName}`}><strong>{o.courierName}</strong>: {o.error}</p>
              ))}
              {estimatedOut.map((o) => (
                <div key={`e-${o.courierName}`} className="text-orange-700">
                  <p>
                    <strong>{o.courierName}</strong>: {FALLBACK_TEXT} — {o.estimated!.join(', ')}
                  </p>
                  {o.reason && <p className="text-xs">Reden van Google: {o.reason}</p>}
                </div>
              ))}
              {skippedOut.map((o) => (
                <p key={`s-${o.courierName}`} className="text-amber-700">
                  <strong>{o.courierName}</strong>: overgeslagen omdat de apotheek geen coördinaten heeft —{' '}
                  {o.skipped!.join(', ')}
                </p>
              ))}
            </div>
          )}

          {!loading && withoutHome.length > 0 && (
            <div className="flex items-start gap-2 rounded-lg bg-amber-50 border border-amber-200 text-amber-800 text-sm p-3">
              <AlertTriangle size={15} className="mt-0.5 shrink-0" />
              <span>
                {withoutHome.length === 1 ? 'Eén koerier heeft' : `${withoutHome.length} koeriers hebben`} nog geen
                standplaats: <strong>{withoutHome.map((h) => h.courierName).join(', ')}</strong>. Hun declaraties
                vallen terug op de drempelregel en worden als onvolledig gemarkeerd.
              </span>
            </div>
          )}

          <ul className="divide-y divide-slate-100">
            {homes.map((h) => {
              const busy = busyId === h.courierId || bulkBusy;
              const open = openId === h.courierId;
              const err = rowError[h.courierId];

              return (
                <li key={h.courierId} className="py-2.5">
                  <div className="flex items-center gap-3">
                    <div className="min-w-0 flex-1">
                      <span className="text-sm font-medium text-slate-800">{h.courierName}</span>
                      <span className="ml-2 text-xs text-slate-500">
                        {h.distances === 0 ? 'geen afstanden' : `${h.distances} afstand${h.distances === 1 ? '' : 'en'}`}
                      </span>
                      <span className={`ml-2 text-xs ${h.hasAddress ? 'text-slate-500' : 'text-amber-700'}`}>
                        · {h.hasAddress ? 'adres bekend' : 'geen adres'}
                      </span>
                    </div>

                    <select
                      value={h.homePharmacyId ?? ''} disabled={busy}
                      onChange={(e) => saveHome(h.courierId, e.target.value)}
                      className="w-56 border border-slate-300 rounded-lg px-2 py-1.5 text-sm bg-white disabled:opacity-60"
                    >
                      <option value="">— geen standplaats —</option>
                      {pharmacies.map((p) => (
                        <option key={p.id} value={p.id}>{p.name}</option>
                      ))}
                    </select>

                    <button
                      onClick={() => openCourier(h.courierId)} disabled={busy}
                      className="px-2.5 py-1 text-sm border border-slate-300 rounded-lg hover:border-slate-400 disabled:opacity-60"
                    >
                      {open ? 'Sluiten' : 'Adres…'}
                    </button>
                  </div>

                  {err && <p className="text-xs text-red-600 mt-1">{err}</p>}

                  {open && (
                    <div className="mt-3 rounded-lg bg-slate-50 border border-slate-200 p-3 space-y-3">
                      <div>
                        <label className="block text-xs text-slate-500 mb-1">
                          Woonadres van {h.courierName} — wordt bewaard, alleen zichtbaar voor planners
                        </label>
                        <div className="flex gap-2">
                          <input
                            type="text" value={address} disabled={busy || addressLoading}
                            placeholder={addressLoading ? 'Adres ophalen…' : 'Straat 12, 1234 AB Plaats'}
                            onChange={(e) => setAddress(e.target.value)}
                            onKeyDown={(e) => { if (e.key === 'Enter') calculate(h.courierId); }}
                            className="flex-1 border border-slate-300 rounded-lg px-2 py-1.5 text-sm bg-white disabled:opacity-60"
                          />
                          <button
                            onClick={() => calculate(h.courierId)} disabled={busy || addressLoading}
                            className="inline-flex items-center gap-1 px-3 py-1.5 text-sm bg-green-600 hover:bg-green-700 disabled:opacity-60 text-white rounded-lg font-medium"
                          >
                            <Calculator size={15} /> {busyId === h.courierId ? 'Bezig…' : 'Berekenen'}
                          </button>
                        </div>
                        <p className="text-xs text-slate-400 mt-1">
                          Er worden meteen afstanden berekend naar álle apotheken waar deze koerier aan
                          gekoppeld is, zodat ook diensten buiten de standplaats kloppen. Een gewijzigd adres
                          wordt eerst opgeslagen.
                        </p>
                      </div>

                      {run && (
                        <div className="text-sm">
                          <p className="inline-flex items-center gap-1 text-green-700 font-medium">
                            <Check size={15} /> {written(run)} afstand{written(run) === 1 ? '' : 'en'} bijgewerkt
                          </p>
                          {run.keptManual > 0 && (
                            <p className="text-slate-600 mt-0.5">
                              {run.keptManual === 1 ? 'Eén handmatige afstand is' : `${run.keptManual} handmatige afstanden zijn`}{' '}
                              blijven staan — de ANWB is leidend. Het getal van Google staat ernaast in de lijst.
                            </p>
                          )}
                          {/* Een schatting telt net zo goed mee in de vergoeding.
                              Vroeger stond hier "waarvan 3 geschat" in groen, en
                              zag niemand dat élke afstand een schatting was. */}
                          {run.fallbacks > 0 && (
                            <div className="mt-1 rounded-lg bg-orange-50 border border-orange-200 text-orange-800 p-2">
                              <p>
                                <strong>
                                  {run.fallbacks === run.distances.length ? 'Alle afstanden' : `${run.fallbacks} van ${run.distances.length} afstanden`}
                                </strong>{' '}
                                {FALLBACK_TEXT}: {estimatedNames(run).join(', ')}.
                              </p>
                              {run.routeError && (
                                <p className="text-xs mt-0.5">Reden van Google: {run.routeError}</p>
                              )}
                            </div>
                          )}
                          {run.skipped.length > 0 && (
                            <p className="text-amber-700 mt-1">
                              Overgeslagen (apotheek zonder coördinaten):{' '}
                              {run.skipped.map((s) => s.name).join(', ')}. Vul die afstanden hieronder met de hand in,
                              of vul eerst het adres van de apotheek aan.
                            </p>
                          )}
                        </div>
                      )}

                      {/* Elke apotheek van de koerier, ook zonder afstand en ook
                          als de berekening niets opleverde. Bij BENU Apotheek
                          Stadsweiden had geen enkele apotheek coördinaten: de
                          functie gaf een fout, en er was nergens een veld om de
                          ANWB-afstand in te vullen. */}
                      <DistanceTable
                        ids={pharmacyIdsFor(h)}
                        existing={existing}
                        pharmacyName={pharmacyName}
                        computedForManual={computedForManual}
                        manual={manual}
                        busy={busy}
                        onManualChange={(id, v) => setManual((m) => ({ ...m, [id]: v }))}
                        onSave={(id) => saveManual(h.courierId, id)}
                        onReset={(id) => resetManual(h.courierId, id)}
                      />
                      <p className="text-xs text-slate-400">
                        Volgens de cao is de ANWB-routeplanner leidend. Een afstand die je hier invult blijft staan
                        bij elke herberekening, tot je hem terugzet.
                      </p>
                    </div>
                  )}
                </li>
              );
            })}
          </ul>

          {!loading && homes.length === 0 && (
            <p className="text-sm text-slate-500">Geen koeriers gevonden.</p>
          )}
        </div>
      </div>
    </div>
  );
}

// De afstanden van één koerier, per apotheek, met een invoerveld op elke regel.
//
// Een handmatige afstand heet hier "handmatig (ANWB)": volgens de cao is de
// ANWB-routeplanner leidend, en het label moet zeggen waarom dit getal voorgaat.
// Daarnaast staat wat Google berekende — alleen na een berekening in dit scherm,
// want dat getal wordt nergens bewaard — zodat een groot verschil opvalt.
function DistanceTable({
  ids, existing, pharmacyName, computedForManual, manual, busy, onManualChange, onSave, onReset,
}: {
  ids: string[];
  existing: CourierDistance[];
  pharmacyName: Map<string, string>;
  computedForManual: Record<string, { km: number; source: string }>;
  manual: Record<string, string>;
  busy: boolean;
  onManualChange: (pharmacyId: string, value: string) => void;
  onSave: (pharmacyId: string) => void;
  onReset: (pharmacyId: string) => void;
}) {
  if (ids.length === 0) {
    return <p className="text-sm text-slate-500">Deze koerier is nog aan geen enkele apotheek gekoppeld.</p>;
  }
  const byId = new Map(existing.map((d) => [d.pharmacyId, d]));

  return (
    <table className="w-full text-sm">
      <tbody className="divide-y divide-slate-200">
        {ids.map((id) => {
          const d = byId.get(id);
          // Ook in de vaste lijst: een geschatte afstand van weken terug is net
          // zo verdacht als een van nu.
          const estimated = d?.source === 'fallback';
          const isManual = d?.source === 'manual';
          const google = computedForManual[id];
          return (
            <tr key={id} className={estimated ? 'text-orange-700' : ''}>
              <td className="py-1.5 pr-2">{pharmacyName.get(id) ?? id}</td>
              <td className="py-1.5 px-2 text-right tabular-nums whitespace-nowrap">
                {d ? kmText(d.distanceKm) : '—'}
              </td>
              <td
                className={`py-1.5 px-2 text-xs whitespace-nowrap ${estimated || isManual ? 'font-medium' : 'text-slate-500'}`}
                title={estimated ? FALLBACK_TEXT : undefined}
              >
                {d ? (SOURCE_LABELS[d.source] ?? d.source) : 'nog geen afstand'}
                {isManual && google && (
                  <span className="block font-normal text-slate-500">
                    Google: {kmText(google.km)}{google.source === 'fallback' ? ' (geschat)' : ''}
                  </span>
                )}
              </td>
              <td className="py-1.5 pl-2">
                <div className="flex items-center justify-end gap-1.5">
                  <input
                    type="text" inputMode="decimal" value={manual[id] ?? ''} disabled={busy}
                    placeholder="km ANWB"
                    onChange={(e) => onManualChange(id, e.target.value)}
                    onKeyDown={(e) => { if (e.key === 'Enter' && manual[id]) onSave(id); }}
                    className="w-20 border border-slate-300 rounded-lg px-2 py-1 text-sm tabular-nums bg-white disabled:opacity-60"
                  />
                  <button
                    onClick={() => onSave(id)} disabled={busy || !manual[id]}
                    className="px-2 py-1 text-xs border border-slate-300 rounded-lg hover:border-slate-400 disabled:opacity-40"
                  >
                    Vastleggen
                  </button>
                  {isManual && (
                    <button
                      onClick={() => onReset(id)} disabled={busy}
                      title="De handmatige afstand weghalen en de berekende waarde gebruiken"
                      className="px-2 py-1 text-xs border border-slate-300 rounded-lg hover:border-slate-400 disabled:opacity-40"
                    >
                      Terugzetten
                    </button>
                  )}
                </div>
              </td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}
