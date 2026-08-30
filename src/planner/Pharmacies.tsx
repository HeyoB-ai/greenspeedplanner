import { useEffect, useMemo, useState } from 'react';
import { Building2, Check, Info, X } from 'lucide-react';
import { Pharmacy } from '../types';
import { getPharmacies, setPharmacyCity } from './plannerService';

interface Props {
  onClose: () => void;
}

// Apotheekbeheer: op dit moment één veld, de plaatsnaam (migratie 024).
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
