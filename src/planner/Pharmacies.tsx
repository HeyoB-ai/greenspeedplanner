import { useEffect, useMemo, useState } from 'react';
import { Building2, Check, Euro, Info, Trash2, X } from 'lucide-react';
import { Chain, Pharmacy, PharmacyRate } from '../types';
import { getPharmacies, setPharmacyBillingEmail, setPharmacyCity } from './plannerService';
import {
  deletePharmacyRate, euro, getChains, getPharmacyRates, setChainBilling, setPharmacyRate,
} from './invoiceService';

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
  const [chains, setChains] = useState<Chain[]>([]);
  const [chainDrafts, setChainDrafts] = useState<Record<string, string>>({});
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
  // Vier tarieven sinds migratie 030. Als tekst, zodat een leeg veld ook echt
  // leeg blijft: geen tarief is iets anders dan een tarief van nul.
  const [rateForm, setRateForm] = useState({
    bike: '', car: '', institution: '', other: '', start: '', from: '', note: '',
  });
  // Adres voor meerwerkmeldingen (migratie 031).
  const [mailDrafts, setMailDrafts] = useState<Record<string, string>>({});

  async function reload() {
    setLoading(true);
    try {
      const [ps, cs] = await Promise.all([getPharmacies(), getChains()]);
      setPharmacies(ps);
      setChains(cs);
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
    setRateForm({
      bike: '', car: '', institution: '', other: '', start: '',
      from: new Date().toISOString().slice(0, 10), note: '',
    });
    setRowError((m) => ({ ...m, [id]: '' }));
    try {
      setRates(await getPharmacyRates(id));
    } catch (e: any) {
      setRowError((m) => ({ ...m, [id]: e?.message ?? 'Tarieven laden mislukt.' }));
    }
  }

  // Leeg veld → null: geen tarief voor dat soort werk. Dat is iets anders dan
  // nul, en de factuurregel zegt het verschil ook.
  function parseRate(raw: string): number | null | 'fout' {
    const t = raw.trim();
    if (t === '') return null;
    const n = Number(t.replace(',', '.'));
    return Number.isFinite(n) && n >= 0 ? n : 'fout';
  }

  async function saveRate(id: string) {
    setRowError((m) => ({ ...m, [id]: '' }));

    const bike = parseRate(rateForm.bike);
    const car = parseRate(rateForm.car);
    const institution = parseRate(rateForm.institution);
    const other = parseRate(rateForm.other);
    const start = parseRate(rateForm.start);

    if ([bike, car, institution, other, start].includes('fout')) {
      setRowError((m) => ({ ...m, [id]: 'Vul geldige bedragen in, of laat een veld leeg.' }));
      return;
    }
    if (bike === null && car === null && institution === null && other === null) {
      setRowError((m) => ({ ...m, [id]: 'Vul minstens één uurtarief in.' }));
      return;
    }
    if (!/^\d{4}-\d{2}-\d{2}$/.test(rateForm.from)) {
      setRowError((m) => ({ ...m, [id]: 'Vul een ingangsdatum in.' }));
      return;
    }

    setBusyId(id);
    try {
      await setPharmacyRate(
        id,
        {
          bike: bike as number | null,
          car: car as number | null,
          institution: institution as number | null,
          other: other as number | null,
          startRate: (start as number | null) ?? 0,
        },
        rateForm.from,
        rateForm.note.trim() || null,
      );
      setRates(await getPharmacyRates(id));
      setRateForm((f) => ({ ...f, bike: '', car: '', institution: '', other: '', start: '', note: '' }));
    } catch (e: any) {
      setRowError((m) => ({ ...m, [id]: e?.message ?? 'Opslaan mislukt.' }));
    } finally {
      setBusyId(null);
    }
  }

  async function saveChain(c: Chain, split: boolean) {
    setBusyId(c.group_id);
    setError('');
    try {
      await setChainBilling(c.group_id, (chainDrafts[c.group_id] ?? c.billing_email ?? '').trim() || null, split);
      setChainDrafts((m) => { const next = { ...m }; delete next[c.group_id]; return next; });
      await reload();
    } catch (e: any) {
      setError(e?.message ?? 'Opslaan mislukt.');
    } finally {
      setBusyId(null);
    }
  }

  async function saveBillingEmail(id: string) {
    setBusyId(id);
    setRowError((m) => ({ ...m, [id]: '' }));
    try {
      await setPharmacyBillingEmail(id, (mailDrafts[id] ?? '').trim() || null);
      setMailDrafts((m) => { const next = { ...m }; delete next[id]; return next; });
      await reload();
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
            onderaan in de groep <strong>Overig</strong>. Het e-mailadres is waar meerwerkmeldingen
            heen gaan; zonder adres kan zo'n melding niet vrijgegeven worden.
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

          {/* ── Ketens ─────────────────────────────────────────────────────
              De splitsing staat standaard uit: dan gaat alles naar het filiaal,
              precies zoals het altijd ging. Aanzetten kan pas met een centraal
              adres, want anders levert het facturen op die nergens heen kunnen. */}
          {chains.length > 0 && (
            <div className="rounded-lg border border-slate-200 p-3 space-y-2">
              <p className="text-sm font-medium text-slate-800">Ketens</p>
              <ul className="divide-y divide-slate-100">
                {chains.map((c) => {
                  const busy = busyId === c.group_id;
                  return (
                    <li key={c.group_id} className="py-2 flex flex-wrap items-center gap-2">
                      <span className="min-w-0 flex-1 text-sm">
                        {c.group_name}
                        <span className="text-slate-400"> · {c.pharmacies} apothe{c.pharmacies === 1 ? 'ek' : 'ken'}</span>
                      </span>
                      <input
                        type="text"
                        value={chainDrafts[c.group_id] ?? c.billing_email ?? ''}
                        placeholder="centraal factuuradres"
                        disabled={busy}
                        onChange={(e) => setChainDrafts((m) => ({ ...m, [c.group_id]: e.target.value }))}
                        onBlur={() => {
                          if ((chainDrafts[c.group_id] ?? '').trim() !== (c.billing_email ?? '')
                              && c.group_id in chainDrafts) saveChain(c, c.split_extra_work);
                        }}
                        className="w-56 border border-slate-300 rounded-lg px-2 py-1.5 text-sm bg-white disabled:opacity-60"
                      />
                      <label className="inline-flex items-center gap-1.5 text-sm text-slate-600 cursor-pointer">
                        <input
                          type="checkbox" checked={c.split_extra_work} disabled={busy}
                          onChange={(e) => saveChain(c, e.target.checked)}
                        />
                        Splitsen
                      </label>
                    </li>
                  );
                })}
              </ul>
              <p className="text-xs text-slate-400">
                <strong>Splitsen</strong> stuurt de gebudgetteerde uren en het starttarief naar het
                centrale adres, en het goedgekeurde meerwerk, de reiskosten en de onkosten naar het
                filiaal. Uit = alles naar het filiaal.
              </p>
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
                    <input
                      type="text"
                      value={mailDrafts[p.id] ?? p.billingEmail ?? ''}
                      placeholder="e-mail voor meerwerk"
                      disabled={busy}
                      onChange={(e) => setMailDrafts((m) => ({ ...m, [p.id]: e.target.value }))}
                      onKeyDown={(e) => { if (e.key === 'Enter') saveBillingEmail(p.id); }}
                      onBlur={() => {
                        if ((mailDrafts[p.id] ?? '').trim() !== (p.billingEmail ?? '')) saveBillingEmail(p.id);
                      }}
                      className={`w-56 border rounded-lg px-2 py-1.5 text-sm bg-white disabled:opacity-60 ${
                        p.billingEmail ? 'border-slate-300' : 'border-amber-300'
                      }`}
                      title="Zonder adres kan een meerwerkmelding niet vrijgegeven worden"
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
                              <th className="font-medium pb-1 text-right">Fiets</th>
                              <th className="font-medium pb-1 text-right">Auto</th>
                              <th className="font-medium pb-1 text-right">Instelling</th>
                              <th className="font-medium pb-1 text-right">Overig</th>
                              <th className="font-medium pb-1 text-right">Start</th>
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
                                <td className="py-1 tabular-nums text-right whitespace-nowrap">{euro(r.hourlyRateBike)}</td>
                                <td className="py-1 tabular-nums text-right whitespace-nowrap">{euro(r.hourlyRateCar)}</td>
                                <td className="py-1 tabular-nums text-right whitespace-nowrap">{euro(r.hourlyRateInstitution)}</td>
                                <td className="py-1 tabular-nums text-right whitespace-nowrap">{euro(r.hourlyRateOther)}</td>
                                <td className="py-1 tabular-nums text-right whitespace-nowrap">{euro(r.startRate)}</td>
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
                        {([
                          ['bike', 'Fiets (€)'],
                          ['car', 'Auto (€)'],
                          ['institution', 'Instelling (€)'],
                          ['other', 'Overig (€)'],
                        ] as const).map(([key, label]) => (
                          <label key={key} className="text-xs text-slate-500">
                            <span className="block mb-1">{label}</span>
                            <input
                              type="text" inputMode="decimal" value={rateForm[key]} disabled={busy}
                              onChange={(e) => setRateForm((f) => ({ ...f, [key]: e.target.value }))}
                              placeholder="leeg = geen"
                              className="w-24 border border-slate-300 rounded-lg px-2 py-1 text-sm tabular-nums bg-white"
                            />
                          </label>
                        ))}
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
                        invoeren corrigeert die regel. Een leeg tariefveld betekent <em>geen tarief
                        voor dat soort werk</em> — een dienst van die soort levert dan een onvolledige
                        factuurregel op in plaats van een nul. Een starttarief van 0 is wél een waarde
                        (BENU-filialen).
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
