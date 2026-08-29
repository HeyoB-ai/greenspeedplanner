import { useEffect, useMemo, useState } from 'react';
import { AlertTriangle, Calculator, Check, Home, X } from 'lucide-react';
import { CourierDistance, CourierHome, Pharmacy } from '../types';
import { getPharmacies } from './plannerService';
import {
  DistanceRun, SOURCE_LABELS, computeDistances, getCourierHomes, getDistances,
  setDistanceManual, setHomePharmacy,
} from './addressService';

interface Props {
  onClose: () => void;
}

// Beheerscherm voor de standplaats en de afstanden per koerier (migratie 018).
//
// Het woonadres wordt HIER ingevoerd en NERGENS bewaard. Het gaat één keer naar
// de Edge Function, die het omzet in afstanden; wat terugkomt zijn kilometers per
// apotheek. Het veld wordt na een geslaagde berekening leeggemaakt, zodat het
// adres ook niet in een openstaand scherm blijft staan.
export default function CourierAddresses({ onClose }: Props) {
  const [homes, setHomes] = useState<CourierHome[]>([]);
  const [pharmacies, setPharmacies] = useState<Pharmacy[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  const [openId, setOpenId] = useState<string | null>(null);
  const [address, setAddress] = useState('');
  const [busyId, setBusyId] = useState<string | null>(null);
  const [rowError, setRowError] = useState<Record<string, string>>({});
  const [run, setRun] = useState<DistanceRun | null>(null);
  const [existing, setExisting] = useState<CourierDistance[]>([]);
  const [manual, setManual] = useState<Record<string, string>>({});

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

  async function openCourier(courierId: string) {
    if (openId === courierId) { setOpenId(null); return; }
    setOpenId(courierId);
    setAddress('');
    setRun(null);
    setManual({});
    setRowError((m) => ({ ...m, [courierId]: '' }));
    try {
      setExisting(await getDistances(courierId));
    } catch {
      setExisting([]);
    }
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
      const result = await computeDistances(courierId, value);
      setRun(result);
      setAddress('');            // het adres blijft niet in beeld staan
      setExisting(await getDistances(courierId));
      await reload();
    } catch (e: any) {
      setRowError((m) => ({ ...m, [courierId]: e?.message ?? 'Berekenen mislukt.' }));
    } finally {
      setBusyId(null);
    }
  }

  async function saveManual(courierId: string, pharmacyId: string) {
    const km = Number((manual[pharmacyId] ?? '').replace(',', '.'));
    if (!Number.isFinite(km) || km < 0) {
      setRowError((m) => ({ ...m, [courierId]: 'Vul een geldig aantal kilometers in.' }));
      return;
    }
    setBusyId(courierId);
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
            <strong>niet opgeslagen</strong> — er komen alleen kilometers terug.
          </p>

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
              const busy = busyId === h.courierId;
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
                          Woonadres van {h.courierName} — wordt niet bewaard
                        </label>
                        <div className="flex gap-2">
                          <input
                            type="text" value={address} disabled={busy}
                            placeholder="Straat 12, 1234 AB Plaats"
                            onChange={(e) => setAddress(e.target.value)}
                            onKeyDown={(e) => { if (e.key === 'Enter') calculate(h.courierId); }}
                            className="flex-1 border border-slate-300 rounded-lg px-2 py-1.5 text-sm bg-white disabled:opacity-60"
                          />
                          <button
                            onClick={() => calculate(h.courierId)} disabled={busy}
                            className="inline-flex items-center gap-1 px-3 py-1.5 text-sm bg-green-600 hover:bg-green-700 disabled:opacity-60 text-white rounded-lg font-medium"
                          >
                            <Calculator size={15} /> {busy ? 'Bezig…' : 'Berekenen'}
                          </button>
                        </div>
                        <p className="text-xs text-slate-400 mt-1">
                          Er worden meteen afstanden berekend naar álle apotheken waar deze koerier aan
                          gekoppeld is, zodat ook diensten buiten de standplaats kloppen.
                        </p>
                      </div>

                      {run && (
                        <div className="text-sm">
                          <p className="inline-flex items-center gap-1 text-green-700 font-medium">
                            <Check size={15} /> {run.distances.length} afstand{run.distances.length === 1 ? '' : 'en'} bijgewerkt
                            {run.fallbacks > 0 && `, waarvan ${run.fallbacks} geschat`}
                          </p>
                          {run.skipped.length > 0 && (
                            <p className="text-amber-700 mt-1">
                              Overgeslagen (apotheek zonder coördinaten):{' '}
                              {run.skipped.map((s) => s.name).join(', ')}. Vul die afstanden hieronder met de hand in,
                              of vul eerst het adres van de apotheek aan.
                            </p>
                          )}
                        </div>
                      )}

                      {existing.length > 0 && (
                        <table className="w-full text-sm">
                          <tbody className="divide-y divide-slate-200">
                            {existing
                              .slice()
                              .sort((a, b) => (pharmacyName.get(a.pharmacyId) ?? '').localeCompare(pharmacyName.get(b.pharmacyId) ?? '', 'nl'))
                              .map((d) => (
                                <tr key={d.pharmacyId}>
                                  <td className="py-1 pr-2">{pharmacyName.get(d.pharmacyId) ?? d.pharmacyId}</td>
                                  <td className="py-1 px-2 text-right tabular-nums">
                                    {d.distanceKm.toFixed(1).replace('.', ',')} km
                                  </td>
                                  <td className="py-1 pl-2 text-xs text-slate-500 w-24">
                                    {SOURCE_LABELS[d.source] ?? d.source}
                                  </td>
                                </tr>
                              ))}
                          </tbody>
                        </table>
                      )}

                      {run && run.skipped.length > 0 && (
                        <div className="space-y-1.5">
                          {run.skipped.map((s) => (
                            <div key={s.id} className="flex items-center gap-2 text-sm">
                              <span className="flex-1 text-slate-700">{s.name}</span>
                              <input
                                type="text" inputMode="decimal" value={manual[s.id] ?? ''} disabled={busy}
                                placeholder="km"
                                onChange={(e) => setManual((m) => ({ ...m, [s.id]: e.target.value }))}
                                className="w-24 border border-slate-300 rounded-lg px-2 py-1 text-sm tabular-nums bg-white disabled:opacity-60"
                              />
                              <button
                                onClick={() => saveManual(h.courierId, s.id)} disabled={busy || !manual[s.id]}
                                className="px-2.5 py-1 text-sm border border-slate-300 rounded-lg hover:border-slate-400 disabled:opacity-40"
                              >
                                Vastleggen
                              </button>
                            </div>
                          ))}
                        </div>
                      )}
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
