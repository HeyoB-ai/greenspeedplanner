import { useEffect, useMemo, useRef, useState } from 'react';
import { AlertTriangle, Info, KeyRound, Upload, UserPlus, Users, X } from 'lucide-react';
import { Employee, EmployeeImportResult, Pharmacy } from '../types';
import { getPharmacies } from './plannerService';
import {
  EmployeeInput, csvToRows, fullName, getEmployees, importEmployees, saveEmployee,
} from './employeeService';

interface Props {
  onClose: () => void;
}

const EMPTY: EmployeeInput = {
  first_name: '', last_name: '', personnel_number: '', email: '', phone: '',
  employment_type: '', hourly_wage: '', wage_start_date: '', home_pharmacy_id: '',
  employed_from: new Date().toISOString().slice(0, 10), employed_until: '', note: '',
};

// Personeelsadministratie (fase 8, migratie 029).
//
// Deze lijst staat los van wie er kan inloggen: de meeste medewerkers krijgen
// voorlopig geen account. Een medewerker gaat hier ook nooit weg — uit dienst is
// een einddatum, want een urenexport over maart moet iemand bevatten die in april
// vertrokken is.
export default function Employees({ onClose }: Props) {
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [pharmacies, setPharmacies] = useState<Pharmacy[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [showInactive, setShowInactive] = useState(false);

  const [form, setForm] = useState<EmployeeInput | null>(null);
  const [importReport, setImportReport] = useState<EmployeeImportResult[] | null>(null);
  const [importWarning, setImportWarning] = useState('');
  const fileRef = useRef<HTMLInputElement>(null);

  async function reload() {
    setLoading(true);
    try {
      const [es, ps] = await Promise.all([getEmployees(), getPharmacies()]);
      setEmployees(es);
      setPharmacies(ps);
      setError('');
    } catch (e: any) {
      setError(e?.message ?? 'Laden mislukt.');
    } finally {
      setLoading(false);
    }
  }
  useEffect(() => { reload(); }, []);

  const shown = useMemo(
    () => (showInactive ? employees : employees.filter((e) => e.isActive)),
    [employees, showInactive]);

  const withoutNumber = useMemo(() => employees.filter((e) => !e.personnelNumber), [employees]);
  const inactiveCount = employees.length - employees.filter((e) => e.isActive).length;
  const pharmacyName = useMemo(
    () => new Map(pharmacies.map((p) => [p.id, p.name])), [pharmacies]);

  function edit(e: Employee) {
    setImportReport(null);
    setForm({
      id: e.id,
      personnel_number: e.personnelNumber ?? '',
      first_name: e.firstName,
      last_name: e.lastName,
      email: e.email ?? '',
      phone: e.phone ?? '',
      employment_type: e.employmentType ?? '',
      hourly_wage: e.hourlyWage != null ? String(e.hourlyWage) : '',
      wage_start_date: e.wageStartDate ?? '',
      home_pharmacy_id: e.homePharmacyId ?? '',
      employed_from: e.employedFrom,
      employed_until: e.employedUntil ?? '',
      note: e.note ?? '',
    });
  }

  async function save() {
    if (!form) return;
    setBusy(true);
    setError('');
    try {
      await saveEmployee(form);
      setForm(null);
      await reload();
    } catch (e: any) {
      setError(e?.message ?? 'Opslaan mislukt.');
    } finally {
      setBusy(false);
    }
  }

  async function handleFile(file: File) {
    setBusy(true);
    setError('');
    setImportWarning('');
    setImportReport(null);
    try {
      const { rows, unmapped } = csvToRows(await file.text());
      if (rows.length === 0) {
        setError('Geen bruikbare rijen gevonden. Verwacht een kop met in elk geval Voornaam en Achternaam.');
        return;
      }
      if (unmapped.length > 0) {
        // Niet blokkeren maar wel zeggen: een verkeerd gespelde kop levert
        // stilzwijgend een lege kolom op, en dat merk je pas veel later.
        setImportWarning(`Deze kolommen zijn niet herkend en zijn overgeslagen: ${unmapped.join(', ')}.`);
      }
      setImportReport(await importEmployees(rows));
      await reload();
    } catch (e: any) {
      setError(e?.message ?? 'Importeren mislukt.');
    } finally {
      setBusy(false);
      if (fileRef.current) fileRef.current.value = '';
    }
  }

  return (
    <div className="fixed inset-0 z-50 bg-black/40 flex items-start justify-center p-4 overflow-y-auto" onClick={onClose}>
      <div
        className="bg-white rounded-xl shadow-lg w-full max-w-[95vw] xl:max-w-[76rem] my-8"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between px-5 py-3 border-b border-slate-200">
          <h2 className="font-semibold text-slate-800 inline-flex items-center gap-2">
            <Users size={16} className="text-green-700" /> Medewerkers
          </h2>
          <button onClick={onClose} className="text-slate-400 hover:text-slate-700"><X size={18} /></button>
        </div>

        <div className="p-5 space-y-4">
          <div className="flex flex-wrap items-center gap-3 text-sm">
            <button
              onClick={() => { setImportReport(null); setForm({ ...EMPTY }); }}
              disabled={busy}
              className="inline-flex items-center gap-1.5 px-3 py-1.5 bg-green-600 hover:bg-green-700 disabled:opacity-60 text-white rounded-lg font-medium"
            >
              <UserPlus size={15} /> Nieuwe medewerker
            </button>

            <label className="inline-flex items-center gap-1.5 px-3 py-1.5 border border-slate-300 rounded-lg cursor-pointer hover:border-slate-400">
              <Upload size={15} /> CSV importeren
              <input
                ref={fileRef} type="file" accept=".csv,text/csv" className="hidden" disabled={busy}
                onChange={(e) => { const f = e.target.files?.[0]; if (f) handleFile(f); }}
              />
            </label>

            <label className="inline-flex items-center gap-1.5 text-slate-600 cursor-pointer">
              <input type="checkbox" checked={showInactive} onChange={(e) => setShowInactive(e.target.checked)} />
              Ook uit dienst {inactiveCount > 0 && `(${inactiveCount})`}
            </label>

            <span className="ml-auto text-slate-500">
              {shown.length} van {employees.length}
            </span>
          </div>

          {error && <p className="text-sm text-red-600">{error}</p>}
          {loading && <p className="text-sm text-slate-500">Laden…</p>}

          {!loading && withoutNumber.length > 0 && (
            <div className="flex items-start gap-2 rounded-lg bg-amber-50 border border-amber-200 text-amber-800 text-sm p-3">
              <AlertTriangle size={15} className="mt-0.5 shrink-0" />
              <span>
                {withoutNumber.length === 1 ? 'Eén medewerker heeft' : `${withoutNumber.length} medewerkers hebben`} geen
                personeelsnummer: <strong>{withoutNumber.map(fullName).join(', ')}</strong>. Ze zijn wel aangemaakt —
                vul het nummer aan zodra het bekend is.
              </span>
            </div>
          )}

          {/* Verslag van de import: per rij wat ermee gebeurd is. "69 verwerkt"
              zegt niets als er drie zijn overgeslagen. */}
          {importReport && (
            <div className="rounded-lg border border-slate-200 p-3 space-y-2">
              <p className="text-sm font-medium text-slate-800">
                Import: {importReport.filter((r) => r.action === 'nieuw').length} nieuw,{' '}
                {importReport.filter((r) => r.action === 'bijgewerkt').length} bijgewerkt,{' '}
                {importReport.filter((r) => r.action === 'overgeslagen').length} overgeslagen
              </p>
              {importWarning && <p className="text-sm text-amber-700">{importWarning}</p>}
              <div className="max-h-48 overflow-y-auto">
                <table className="w-full text-xs">
                  <tbody className="divide-y divide-slate-100">
                    {importReport
                      .filter((r) => r.action !== 'bijgewerkt' || r.note)
                      .map((r) => (
                        <tr key={r.row_number} className={r.action === 'overgeslagen' ? 'text-red-700' : ''}>
                          <td className="py-1 pr-2 text-slate-400 tabular-nums">{r.row_number}</td>
                          <td className="py-1 pr-2">{r.full_name}</td>
                          <td className="py-1 pr-2 text-slate-500">{r.personnel_number ?? '—'}</td>
                          <td className="py-1 pr-2">{r.action}</td>
                          <td className="py-1 text-amber-700">{r.note}</td>
                        </tr>
                      ))}
                  </tbody>
                </table>
              </div>
              <button onClick={() => setImportReport(null)} className="text-xs text-slate-500 hover:text-slate-800 underline">
                Verslag sluiten
              </button>
            </div>
          )}

          {/* ── Formulier ────────────────────────────────────────────────── */}
          {form && (
            <div className="rounded-lg bg-slate-50 border border-slate-200 p-4 space-y-3">
              <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
                <Field label="Voornaam">
                  <input value={form.first_name} disabled={busy}
                    onChange={(e) => setForm({ ...form, first_name: e.target.value })}
                    className="w-full border border-slate-300 rounded-lg px-2 py-1.5 text-sm bg-white" />
                </Field>
                <Field label="Achternaam">
                  <input value={form.last_name} disabled={busy}
                    onChange={(e) => setForm({ ...form, last_name: e.target.value })}
                    className="w-full border border-slate-300 rounded-lg px-2 py-1.5 text-sm bg-white" />
                </Field>
                <Field label="Personeelsnummer">
                  <input value={form.personnel_number ?? ''} disabled={busy} placeholder="leeg mag"
                    onChange={(e) => setForm({ ...form, personnel_number: e.target.value })}
                    className="w-full border border-slate-300 rounded-lg px-2 py-1.5 text-sm bg-white" />
                </Field>
                <Field label="E-mail">
                  <input value={form.email ?? ''} disabled={busy} placeholder="voor de nadeclaratiemail"
                    onChange={(e) => setForm({ ...form, email: e.target.value })}
                    className="w-full border border-slate-300 rounded-lg px-2 py-1.5 text-sm bg-white" />
                </Field>
                <Field label="Telefoon">
                  <input value={form.phone ?? ''} disabled={busy} placeholder="voor de SMS"
                    onChange={(e) => setForm({ ...form, phone: e.target.value })}
                    className="w-full border border-slate-300 rounded-lg px-2 py-1.5 text-sm bg-white" />
                </Field>
                <Field label="Dienstverband">
                  <select value={form.employment_type ?? ''} disabled={busy}
                    onChange={(e) => setForm({ ...form, employment_type: e.target.value })}
                    className="w-full border border-slate-300 rounded-lg px-2 py-1.5 text-sm bg-white">
                    <option value="">— onbekend —</option>
                    <option value="loondienst">Loondienst</option>
                    <option value="zzp">ZZP</option>
                  </select>
                </Field>
                <Field label="Uurloon (€)">
                  <input value={form.hourly_wage ?? ''} disabled={busy} inputMode="decimal"
                    onChange={(e) => setForm({ ...form, hourly_wage: e.target.value })}
                    className="w-full border border-slate-300 rounded-lg px-2 py-1.5 text-sm tabular-nums bg-white" />
                </Field>
                <Field label="Loon geldig vanaf">
                  <input type="date" value={form.wage_start_date ?? ''} disabled={busy}
                    onChange={(e) => setForm({ ...form, wage_start_date: e.target.value })}
                    className="w-full border border-slate-300 rounded-lg px-2 py-1.5 text-sm bg-white" />
                </Field>
                <Field label="Standplaats">
                  <select value={form.home_pharmacy_id ?? ''} disabled={busy}
                    onChange={(e) => setForm({ ...form, home_pharmacy_id: e.target.value })}
                    className="w-full border border-slate-300 rounded-lg px-2 py-1.5 text-sm bg-white">
                    <option value="">— geen —</option>
                    {pharmacies.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
                  </select>
                </Field>
                <Field label="In dienst vanaf">
                  <input type="date" value={form.employed_from ?? ''} disabled={busy}
                    onChange={(e) => setForm({ ...form, employed_from: e.target.value })}
                    className="w-full border border-slate-300 rounded-lg px-2 py-1.5 text-sm bg-white" />
                </Field>
                <Field label="Uit dienst per">
                  <input type="date" value={form.employed_until ?? ''} disabled={busy}
                    onChange={(e) => setForm({ ...form, employed_until: e.target.value })}
                    className="w-full border border-slate-300 rounded-lg px-2 py-1.5 text-sm bg-white" />
                </Field>
              </div>

              <p className="text-xs text-slate-500">
                Uit dienst is een datum, geen verwijdering: wie eruit gaat verdwijnt uit de planning,
                maar blijft in een urenexport over de periode dat hij er nog was.
              </p>

              <div className="flex justify-end gap-2">
                <button onClick={() => setForm(null)} disabled={busy}
                  className="px-3 py-1.5 text-sm text-slate-600 hover:text-slate-900 disabled:opacity-60">
                  Annuleren
                </button>
                <button onClick={save} disabled={busy}
                  className="px-3 py-1.5 text-sm bg-green-600 hover:bg-green-700 disabled:opacity-60 text-white rounded-lg font-medium">
                  {busy ? 'Opslaan…' : 'Opslaan'}
                </button>
              </div>
            </div>
          )}

          {/* ── Lijst ────────────────────────────────────────────────────── */}
          {shown.length > 0 && (
            <div className="overflow-x-auto">
              <table className="w-full min-w-[56rem] text-sm">
                <thead>
                  <tr className="text-left text-xs uppercase tracking-wide text-slate-500 border-b border-slate-200">
                    <th className="py-2 pr-3 font-medium">Nr.</th>
                    <th className="py-2 px-3 font-medium">Naam</th>
                    <th className="py-2 px-3 font-medium">Dienstverband</th>
                    <th className="py-2 px-3 font-medium">Standplaats</th>
                    <th className="py-2 px-3 font-medium">In dienst</th>
                    <th className="py-2 px-3 font-medium">Inlog</th>
                    <th className="py-2 pl-3 font-medium"></th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {shown.map((e) => (
                    <tr key={e.id} className={!e.isActive ? 'text-slate-400' : undefined}>
                      <td className="py-2 pr-3 tabular-nums whitespace-nowrap">
                        {e.personnelNumber ?? <span className="text-amber-600">geen</span>}
                      </td>
                      <td className="py-2 px-3 whitespace-nowrap">{fullName(e)}</td>
                      <td className="py-2 px-3 whitespace-nowrap">{e.employmentType ?? '—'}</td>
                      <td className="py-2 px-3">
                        {e.homePharmacyId ? (pharmacyName.get(e.homePharmacyId) ?? e.homePharmacyId) : '—'}
                      </td>
                      <td className="py-2 px-3 tabular-nums whitespace-nowrap">
                        {e.employedFrom}
                        {e.employedUntil && <span className="text-slate-400"> t/m {e.employedUntil}</span>}
                      </td>
                      <td className="py-2 px-3">
                        {e.userProfileId
                          ? <span className="inline-flex items-center gap-1 text-green-700"><KeyRound size={13} /> ja</span>
                          : <span className="text-slate-400">nee</span>}
                      </td>
                      <td className="py-2 pl-3 text-right">
                        <button onClick={() => edit(e)} disabled={busy}
                          className="text-slate-500 hover:text-green-700 disabled:opacity-60">
                          Bewerken
                        </button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}

          {!loading && shown.length === 0 && (
            <p className="text-sm text-slate-500">
              Geen medewerkers om te tonen{!showInactive && employees.length > 0 && ' — allemaal uit dienst'}.
            </p>
          )}

          <details className="group">
            <summary className="inline-flex cursor-pointer list-none items-center gap-1.5 text-xs text-slate-400 hover:text-slate-600 [&::-webkit-details-marker]:hidden">
              <Info size={13} />
              Hoe werkt de import?
            </summary>
            <div className="mt-2 space-y-2 border-l-2 border-slate-100 pl-3 text-xs text-slate-500">
              <p>
                Een CSV met een kopregel. Herkend worden onder meer <strong>Personeelsnummer</strong>,{' '}
                <strong>Voornaam</strong>, <strong>Achternaam</strong>, <strong>E-mail</strong>,{' '}
                <strong>Telefoon</strong>, <strong>Dienstverband</strong>, <strong>Uurloon</strong>,{' '}
                <strong>In dienst</strong> en <strong>Uit dienst</strong>. Komma's en puntkomma's mogen
                allebei als scheidingsteken.
              </p>
              <p>
                Er wordt gekoppeld op personeelsnummer, en anders op voor- en achternaam. Bestaat de
                medewerker al, dan wordt hij <strong>bijgewerkt en niet verdubbeld</strong> — je kunt
                dezelfde lijst dus opnieuw draaien als er een kolom verkeerd stond. Een lege kolom
                overschrijft niets.
              </p>
              <p>
                Zonder personeelsnummer wordt iemand gewoon aangemaakt, met een markering bovenaan
                deze lijst. Weigeren zou betekenen dat de lijst eerst met de hand moet worden
                aangevuld, en dan wordt hij niet gedraaid.
              </p>
            </div>
          </details>
        </div>
      </div>
    </div>
  );
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="block">
      <span className="block text-xs text-slate-500 mb-1">{label}</span>
      {children}
    </label>
  );
}
