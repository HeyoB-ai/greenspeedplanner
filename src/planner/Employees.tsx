import { useEffect, useMemo, useRef, useState } from 'react';
import { AlertTriangle, Info, KeyRound, Upload, UserPlus, Users, X } from 'lucide-react';
import { CourierContact, Employee, EmployeeImportResult, Pharmacy } from '../types';
import { getPharmacies } from './plannerService';
import {
  EmployeeInput, csvToRows, fullName, getEmployees, importEmployees, saveEmployee,
} from './employeeService';
// Het telefoonnummer hoort in courier_contacts en niet in employees.phone: daar
// geldt de CHECK op E.164 en daar kijkt de SMS-keten naar. Dit scherm bewerkt dus
// dezelfde rij als Beheer > Nummers, met dezelfde normalisatie. Zie migratie 043.
import {
  deleteContact, getContacts, normalizePhone, phoneWarning, saveContact,
} from './contactService';

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
  const [contacts, setContacts] = useState<CourierContact[]>([]);
  // Het nummer staat los van `form`: het gaat naar een andere tabel dan de rest van
  // het formulier, en de invoer is vrije tekst die pas bij het opslaan door
  // normalizePhone() gaat.
  const [phoneDraft, setPhoneDraft] = useState('');

  async function reload() {
    setLoading(true);
    try {
      const [es, ps, cs] = await Promise.all([getEmployees(), getPharmacies(), getContacts()]);
      setEmployees(es);
      setPharmacies(ps);
      setContacts(cs);
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

  // Wie er werkelijk een personeelsnummer mist. Twee beperkingen op de oude
  // filter, want die telde iedereen zonder nummer en noemde dus namen waar niets
  // aan te doen valt:
  //
  //   * ALLEEN WIE IN DIENST IS. Iemand met een employed_until in het verleden
  //     krijgt geen nummer meer. Dit volgt bewust isActive en niet de
  //     showInactive-schakelaar hierboven: die schakelaar bepaalt wat je wílt zien,
  //     niet wie er nog een nummer nodig heeft.
  //   * ALLEEN LOONDIENST. Een zzp'er staat niet op de loonlijst en krijgt er nooit
  //     een; die in de balk noemen is een taak verzinnen die niet bestaat.
  const needsNumber = useMemo(
    () => employees.filter((e) => e.isActive
                               && e.employmentType === 'loondienst'
                               && !e.personnelNumber),
    [employees]);

  // Dienstverband niet ingevuld → we weten niet OF er een nummer bij hoort. Deze
  // stil weglaten zou net zo misleidend zijn als ze meetellen: in beide gevallen
  // staat er een getal dat iets beweert wat niemand heeft nagekeken. Dus apart
  // genoemd, met de onzekerheid erin, zodat de planning het dienstverband invult in
  // plaats van te gokken.
  const unknownType = useMemo(
    () => employees.filter((e) => e.isActive
                               && !e.employmentType
                               && !e.personnelNumber),
    [employees]);
  const inactiveCount = employees.length - employees.filter((e) => e.isActive).length;
  const pharmacyName = useMemo(
    () => new Map(pharmacies.map((p) => [p.id, p.name])), [pharmacies]);

  const contactByCourier = useMemo(
    () => new Map(contacts.map((c) => [c.courierId, c])), [contacts]);

  // De medewerker die nu in het formulier staat. Nodig voor user_profile_id: zonder
  // inlogaccount is er geen koerier om een nummer aan te hangen.
  const editing = useMemo(
    () => (form?.id ? employees.find((e) => e.id === form.id) ?? null : null),
    [employees, form]);
  const linkedCourier = editing?.userProfileId ?? null;
  // Bij een nieuwe medewerker bestaat het account nog niet, dus ook nog geen plek
  // voor het nummer. Eerst opslaan en koppelen, dan het nummer.
  const phoneDisabled = busy || !linkedCourier;

  // Waarschuwing en geen blokkade: een SMS naar een vaste lijn verdwijnt geruisloos,
  // dus je wilt een seintje en geen slot. Zelfde functie als het contactenscherm
  // gebruikt, zodat de twee schermen dezelfde grens trekken.
  const phoneHint = useMemo(() => {
    const raw = phoneDraft.trim();
    if (raw === '') return null;
    const parsed = normalizePhone(raw);
    return parsed.ok ? phoneWarning(parsed.e164) : null;
  }, [phoneDraft]);

  function edit(e: Employee) {
    setImportReport(null);
    setForm({
      id: e.id,
      personnel_number: e.personnelNumber ?? '',
      first_name: e.firstName,
      last_name: e.lastName,
      email: e.email ?? '',
      // LAAT DIT STAAN. Het veld is niet meer te bewerken en employee_save() negeert
      // het sinds migratie 043 — maar het meesturen maakt de uitrolvolgorde
      // onschadelijk. Draait de frontend vóór de migratie, dan schrijft de OUDE
      // functie hier dezelfde waarde terug die er al stond. Zou de frontend phone
      // helemaal niet meer meesturen, dan zou die oude functie de kolom op NULL
      // zetten en precies de nummers wissen die nog met de hand overgezet moeten
      // worden.
      phone: e.phone ?? '',
      employment_type: e.employmentType ?? '',
      hourly_wage: e.hourlyWage != null ? String(e.hourlyWage) : '',
      wage_start_date: e.wageStartDate ?? '',
      home_pharmacy_id: e.homePharmacyId ?? '',
      employed_from: e.employedFrom,
      employed_until: e.employedUntil ?? '',
      note: e.note ?? '',
    });
    // Uit courier_contacts, niet uit e.phone: dat laatste is sinds migratie 043 geen
    // bron meer en kan een oude, niet-overgezette waarde bevatten.
    setPhoneDraft(e.userProfileId
      ? contactByCourier.get(e.userProfileId)?.phoneE164 ?? ''
      : '');
  }

  async function save() {
    if (!form) return;

    // Het nummer EERST valideren, vóór er iets is weggeschreven. Anders staat de
    // medewerker al opgeslagen terwijl de foutmelding over het nummer gaat, en dan
    // is niet te zien wat er wel en niet is gelukt.
    const raw = phoneDraft.trim();
    let e164: string | null = null;
    if (linkedCourier && raw !== '') {
      const parsed = normalizePhone(raw);
      if (!parsed.ok) { setError(parsed.reason); return; }
      e164 = parsed.e164;
    }

    setBusy(true);
    setError('');
    try {
      await saveEmployee(form);

      // Het nummer gaat naar courier_contacts — dezelfde rij die Beheer > Nummers
      // bewerkt. Leeggemaakt veld betekent: nummer weg, want anders blijft er een
      // nummer in de SMS-keten staan dat de planner net heeft gewist.
      if (linkedCourier) {
        const current = contactByCourier.get(linkedCourier)?.phoneE164 ?? '';
        if (e164 && e164 !== current) {
          await saveContact(linkedCourier, e164, contactByCourier.get(linkedCourier)?.note ?? null);
        } else if (!e164 && current !== '') {
          await deleteContact(linkedCourier);
        }
      }

      setForm(null);
      setPhoneDraft('');
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
              onClick={() => { setImportReport(null); setForm({ ...EMPTY }); setPhoneDraft(''); }}
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

          {!loading && (needsNumber.length > 0 || unknownType.length > 0) && (
            <div className="flex items-start gap-2 rounded-lg bg-amber-50 border border-amber-200 text-amber-800 text-sm p-3">
              <AlertTriangle size={15} className="mt-0.5 shrink-0" />
              <span>
                {needsNumber.length > 0 && (
                  <>
                    {needsNumber.length === 1
                      ? 'Eén medewerker in loondienst heeft'
                      : `${needsNumber.length} medewerkers in loondienst hebben`} geen
                    personeelsnummer: <strong>{needsNumber.map(fullName).join(', ')}</strong>. Ze zijn wel
                    aangemaakt — vul het nummer aan zodra het bekend is.
                  </>
                )}
                {needsNumber.length > 0 && unknownType.length > 0 && ' '}
                {unknownType.length > 0 && (
                  <>
                    Van {unknownType.length === 1 ? 'één medewerker' : `${unknownType.length} medewerkers`} is het
                    dienstverband niet ingevuld, dus is onbekend of er een personeelsnummer bij hoort:{' '}
                    <strong>{unknownType.map(fullName).join(', ')}</strong>. Vul het dienstverband in, dan
                    verdwijnt deze regel of komt de naam hierboven te staan.
                  </>
                )}
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
                {/* Dit veld schrijft naar courier_contacts en niet naar
                    employees.phone (migratie 043). Het bewerkt dus letterlijk
                    dezelfde rij als Beheer > Nummers; wat je hier invult, gaat de
                    SMS-keten in. Vrije invoer — normalizePhone() maakt er bij het
                    opslaan E.164 van, net als in dat andere scherm. */}
                <Field label="Telefoon">
                  <input value={phoneDraft} disabled={phoneDisabled}
                    placeholder={linkedCourier ? '06… of +316…' : 'eerst een account koppelen'}
                    onChange={(e) => setPhoneDraft(e.target.value)}
                    className="w-full border border-slate-300 rounded-lg px-2 py-1.5 text-sm bg-white disabled:bg-slate-50 disabled:text-slate-400" />
                  {!linkedCourier ? (
                    <p className="text-[11px] text-slate-500 mt-1">
                      Geen inlogaccount gekoppeld. Een SMS gaat naar de koerier achter dat account, dus
                      zonder koppeling is er geen plek voor het nummer. Sla eerst op en koppel een
                      account met de sleutelknop in de lijst.
                    </p>
                  ) : (
                    <p className="text-[11px] text-slate-500 mt-1">
                      Gaat naar de SMS-keten. Hetzelfde nummer als in Beheer &rarr; Nummers.
                      {phoneHint && <span className="text-amber-700"> {phoneHint}</span>}
                    </p>
                  )}
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
