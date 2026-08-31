import { useEffect, useMemo, useState } from 'react';
import { Building2, Check, Euro, Info, Trash2, X } from 'lucide-react';
import { Pharmacy, PharmacyRate } from '../types';
import { getPharmacies, setPharmacyCity } from './plannerService';
import { deletePharmacyRate, euro, getPharmacyRates, setPharmacyRate } from './invoiceService';

interface Props {
  onClose: () => void;
}

// Apotheekbeheer: de plaatsnaam (migratie 024) en de tarieven (migratie 025).
//
// Die plaats bestond al in het schema van de bezorg-app, maar was nergens te
// vullen. Hij wordt hier met de hand ingevoerd en niet uit het adres gevist: de
// schrijfwijzen lopen uiteen, dus een parser doet het meestal goed en soms stil
// fout — en dan staan "Hilversum" en "1213 BE Hilversum" als twee plaatsen in
// het weekoverzicht. Een foute groepering is erger dan geen groepering.
//
// Schrijven gaat via set_pharmacy_city(); de tabel zelf krijgt geen
// schrijfrechten, want die zouden voor élke kolom gelden.
export default function Pharmacies({ onClose }: Props) {
  const [pharmacies, setPharmacies] = useState<Pharmacy[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [busyId, setBusyId] = useState<string | null>(null);
  const [rowError, setRowError] = useState<Record<string, string>>({});
  const [savedId, setSavedId] = useState<string | null>(null);

  // Tarieven van één opengeklapte apotheek (fase 7). Eén tegelijk: de lijst is
  // kort en twee open panelen naast elkaar leest niemand.
  const [openId, setOpenId] = useState<string | null>(null);
  const [rates, setRates] = useState<PharmacyRate[]>([]);
  const [rateForm, setRateForm] = useState({ hourly: '', start: '', from: '', note: '' });

  async function reload() {
    setLoading(true);
    try {
      setPharmacies(await getPharmacies());
      setDrafts({});
      setError('');
    } catch (e: any) {
      setError(e?.message ?? 'Laden mislukt.');
    } finally {
      setLoading(false);
    }
  }
  useEffect(() => { reload(); }, []);

  const missing = useMemo(() => pharmacies.filter((p) => !p.city), [pharmacies]);

  // Bestaande plaatsen als suggestielijst. Zo typt niemand "Hilversum " naast
  // "Hilversum" en valt een apotheek niet in een groep van één.
  const knownCities = useMemo(
    () => [...new Set(pharmacies.map((p) => p.city).filter(Boolean) as string[])].sort(
      (a, b) => a.localeCompare(b, 'nl')),
    [pharmacies],
  );

  function currentValue(id: string): string {
    return drafts[id] ?? pharmacies.find((p) => p.id === id)?.city ?? '';
  }

  function isDirty(id: string): boolean {
    if (!(id in drafts)) return false;
    return drafts[id].trim() !== (pharmacies.find((p) => p.id === id)?.city ?? '');
  }

  async function openRates(id: string) {
    if (openId === id) { setOpenId(null); return; }
    setOpenId(id);
    setRates([]);
    setRateForm({ hourly: '', start: '', from: new Date().toISOString().slice(0, 10), note: '' });
    setRowError((m) => ({ ...m, [id]: '' }));
    try {
      setRates(await getPharmacyRates(id));
    } catch (e: any) {
      setRowError((m) => ({ ...m, [id]: e?.message ?? 'Tarieven laden mislukt.' }));
    }
  }

  async function saveRate(id: string) {
    const hourly = Number(rateForm.hourly.replace(',', '.'));
    const start = rateForm.start.trim() === '' ? 0 : Number(rateForm.start.replace(',', '.'));
    setRowError((m) => ({ ...m, [id]: '' }));

    if (!Number.isFinite(hourly) || hourly < 0) {
      setRowError((m) => ({ ...m, [id]: 'Vul een geldig uurtarief in.' }));
      return;
    }
    if (!Number.isFinite(start) || start < 0) {
      setRowError((m) => ({ ...m, [id]: 'Vul een geldig starttarief in.' }));
      return;
    }
    if (!/^\d{4}-\d{2}-\d{2}$/.test(rateForm.from)) {
      setRowError((m) => ({ ...m, [id]: 'Vul een ingangsdatum in.' }));
      return;
    }

    setBusyId(id);
    try {
      await setPharmacyRate(id, hourly, start, rateForm.from, rateForm.note.trim() || null);
      setRates(await getPharmacyRates(id));
      setRateForm((f) => ({ ...f, hourly: '', start: '', note: '' }));
    } catch (e: any) {
      setRowError((m) => ({ ...m, [id]: e?.message ?? 'Opslaan mislukt.' }));
    } finally {
      setBusyId(null);
    }
  }

  async function removeRate(pharmacyId: string, rateId: string) {
    setBusyId(pharmacyId);
    try {
      await deletePharmacyRate(rateId);
      setRates(await getPharmacyRates(pharmacyId));
    } catch (e: any) {
      setRowError((m) => ({ ...m, [pharmacyId]: e?.message ?? 'Verwijderen mislukt.' }));
    } finally {
      setBusyId(null);
    }
  }

  async function save(id: string) {
    setBusyId(id);
    setRowError((m) => ({ ...m, [id]: '' }));
    try {
      await setPharmacyCity(id, currentValue(id).trim() || null);
      setSavedId(id);
      setTimeout(() => setSavedId((x) => (x === id ? null : x)), 2000);
      await reload();
    } catch (e: any) {
      setRowError((m) => ({ ...m, [id]: e?.message ?? 'Opslaan mislukt.' }));
    } finally {
      setBusyId(null);
    }
  }

  return (
    <div className="fixed inset-0 z-50 bg-black/40 flex items-start justify-center p-4 overflow-y-auto" onClick={onClose}>
      <div className="bg-white rounded-xl shadow-lg w-full max-w-2xl my-8" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between px-5 py-3 border-b border-slate-200">
          <h2 className="font-semibold text-slate-800 inline-flex items-center gap-2">
            <Building2 size={16} className="text-green-700" /> Apotheken
          </h2>
          <button onClick={onClose} className="text-slate-400 hover:text-slate-700"><X size={18} /></button>
        </div>

        <div className="p-5 space-y-4">
          {error && <p className="text-sm text-red-600">{error}</p>}
          {loading && <p className="text-sm text-slate-500">Laden…</p>}

          <p className="text-sm text-slate-600">
            De plaats bepaalt de groepen in het weekoverzicht. Apotheken zonder plaats komen
            onderaan in de groep <strong>Overig</strong>.
          </p>

          {!loading && missing.length > 0 && (
            <div className="flex items-start gap-2 rounded-lg bg-slate-50 border border-slate-200 text-slate-600 text-sm p-3">
              <Info size={15} className="mt-0.5 shrink-0 text-slate-400" />
              <span>
                {missing.length === 1 ? 'Eén apotheek heeft' : `${missing.length} apotheken hebben`} nog
                geen plaats. Groeperen werkt pas goed als ze allemaal gevuld zijn.
              </span>
            </div>
          )}

          {/* Bestaande plaatsen als datalist: één klik in plaats van overtypen,
              en daarmee minder kans op twee schrijfwijzen van dezelfde plaats. */}
          <datalist id="bekende-plaatsen">
            {knownCities.map((c) => <option key={c} value={c} />)}
          </datalist>

          <ul className="divide-y divide-slate-100">
            {pharmacies.map((p) => {
              const busy = busyId === p.id;
              const dirty = isDirty(p.id);
              const err = rowError[p.id];

              return (
                <li key={p.id} className="py-2.5">
                  <div className="flex items-center gap-3">
                    <span className="min-w-0 flex-1 text-sm font-medium text-slate-800 truncate" title={p.name}>
                      {p.name}
                    </span>
                    <input
                      type="text"
                      list="bekende-plaatsen"
                      value={currentValue(p.id)}
                      placeholder="Plaats"
                      disabled={busy}
                      onChange={(e) => setDrafts((d) => ({ ...d, [p.id]: e.target.value }))}
                      onKeyDown={(e) => { if (e.key === 'Enter' && dirty) save(p.id); }}
                      className="w-48 border border-slate-300 rounded-lg px-2 py-1.5 text-sm bg-white disabled:opacity-60"
                    />
                    <button
                      onClick={() => openRates(p.id)} disabled={busy}
                      className="inline-flex items-center gap-1 px-2 py-1 text-sm border border-slate-300 rounded-lg hover:border-slate-400 disabled:opacity-60 shrink-0"
                      title="Uurtarief en starttarief van deze apotheek"
                    >
                      <Euro size={14} /> Tarieven
                    </button>
                    <div className="w-24 shrink-0 flex items-center justify-end">
                      {dirty && (
                        <button
                          onClick={() => save(p.id)} disabled={busy}
                          className="px-2.5 py-1 text-sm bg-green-600 hover:bg-green-700 disabled:opacity-60 text-white rounded-lg font-medium"
                        >
                          {busy ? '…' : 'Opslaan'}
                        </button>
                      )}
                      {!dirty && savedId === p.id && (
                        <span className="inline-flex items-center gap-1 text-sm text-green-700"><Check size={15} /> Opgeslagen</span>
                      )}
                    </div>
                  </div>
                  {err && <p className="text-xs text-red-600 mt-1">{err}</p>}

                  {/* Tarieven van deze apotheek. Een wijziging is een NIEUWE rij
                      met een eigen ingangsdatum: een oude factuur moet later nog
                      met het toen geldende tarief te herleiden zijn. Dezelfde
                      datum opnieuw invoeren corrigeert die ene rij. */}
                  {openId === p.id && (
                    <div className="mt-3 rounded-lg bg-slate-50 border border-slate-200 p-3 space-y-3">
                      {rates.length > 0 ? (
                        <table className="w-full text-sm">
                          <thead>
                            <tr className="text-left text-xs uppercase tracking-wide text-slate-500">
                              <th className="font-medium pb-1">Vanaf</th>
                              <th className="font-medium pb-1">Per uur</th>
                              <th className="font-medium pb-1">Start</th>
                              <th className="font-medium pb-1"></th>
                            </tr>
                          </thead>
                          <tbody className="divide-y divide-slate-200">
                            {rates.map((r, i) => (
                              <tr key={r.id}>
                                <td className="py-1 tabular-nums">
                                  {r.effectiveFrom}
                                  {i === 0 && <span className="ml-1.5 text-xs text-green-700">huidig</span>}
                                </td>
                                <td className="py-1 tabular-nums">{euro(r.hourlyRate)}</td>
                                <td className="py-1 tabular-nums">{euro(r.startRate)}</td>
                                <td className="py-1 text-right">
                                  <button
                                    onClick={() => removeRate(p.id, r.id)} disabled={busy}
                                    className="text-slate-400 hover:text-red-600 disabled:opacity-60"
                                    title="Alleen voor een verkeerd ingevoerde rij — een tarief dat echt gegolden heeft laat je staan"
                                  >
                                    <Trash2 size={14} />
                                  </button>
                                </td>
                              </tr>
                            ))}
                          </tbody>
                        </table>
                      ) : (
                        <p className="text-sm text-amber-700">
                          Nog geen tarief. Zonder tarief blijven de factuurregels van deze apotheek
                          zonder bedrag en gemarkeerd staan.
                        </p>
                      )}

                      <div className="flex flex-wrap items-end gap-2">
                        <label className="text-xs text-slate-500">
                          <span className="block mb-1">Per uur (€)</span>
                          <input
                            type="text" inputMode="decimal" value={rateForm.hourly} disabled={busy}
                            onChange={(e) => setRateForm((f) => ({ ...f, hourly: e.target.value }))}
                            placeholder="0,00"
                            className="w-24 border border-slate-300 rounded-lg px-2 py-1 text-sm tabular-nums bg-white"
                          />
                        </label>
                        <label className="text-xs text-slate-500">
                          <span className="block mb-1">Starttarief (€)</span>
                          <input
                            type="text" inputMode="decimal" value={rateForm.start} disabled={busy}
                            onChange={(e) => setRateForm((f) => ({ ...f, start: e.target.value }))}
                            placeholder="0,00"
                            className="w-24 border border-slate-300 rounded-lg px-2 py-1 text-sm tabular-nums bg-white"
                          />
                        </label>
                        <label className="text-xs text-slate-500">
                          <span className="block mb-1">Vanaf</span>
                          <input
                            type="date" value={rateForm.from} disabled={busy}
                            onChange={(e) => setRateForm((f) => ({ ...f, from: e.target.value }))}
                            className="border border-slate-300 rounded-lg px-2 py-1 text-sm bg-white"
                          />
                        </label>
                        <button
                          onClick={() => saveRate(p.id)} disabled={busy}
                          className="px-3 py-1.5 text-sm bg-green-600 hover:bg-green-700 disabled:opacity-60 text-white rounded-lg font-medium"
                        >
                          {busy ? '…' : 'Vastleggen'}
                        </button>
                      </div>

                      <p className="text-xs text-slate-400">
                        Een tariefwijziging is een nieuwe regel met een eigen ingangsdatum; de oude
                        blijft staan zodat een oude factuur herleidbaar blijft. Dezelfde datum opnieuw
                        invoeren corrigeert die regel.
                      </p>
                    </div>
                  )}
                </li>
              );
            })}
          </ul>

          {!loading && pharmacies.length === 0 && (
            <p className="text-sm text-slate-500">Geen apotheken gevonden.</p>
          )}

          <p className="text-xs text-slate-400">
            De plaats wordt bewust niet uit het adres afgeleid: de schrijfwijzen lopen uiteen, en een
            groep die er goed uitziet maar fout is valt niemand op. Leeg opslaan zet de apotheek terug
            naar Overig.
          </p>
        </div>
      </div>
    </div>
  );
}
