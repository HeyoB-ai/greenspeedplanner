import { FormEvent, useEffect, useMemo, useState } from 'react';
import { AlertTriangle, X } from 'lucide-react';
import { Courier, Institution, Pharmacy, Shift, ShiftType, TransportMode } from '../types';
import { createShift, getCouriers, getCourierShiftsOnDate, getInstitutions, getPharmacies, updateShift } from './plannerService';
import { pairLevel } from './conflicts';
import { CAR_OWNER_OPTIONS, SHIFT_TYPES, TRANSPORT_LABELS, TYPE_STYLES } from './constants';

interface Props {
  // Aanwezig => bewerkmodus. Afwezig => aanmaakmodus.
  shift?: Shift;
  // Aanmaakmodus: voorgeselecteerde apotheek + datum van de aangeklikte cel.
  initialPharmacyId?: string;
  initialDateISO?: string;
  onClose: () => void;
  onSaved: () => void;
}

export default function ShiftForm({ shift, initialPharmacyId, initialDateISO, onClose, onSaved }: Props) {
  const isEdit = !!shift;
  // Datum ligt vast (uit de aangeklikte cel bij aanmaken, uit de dienst bij bewerken).
  const shiftDate = shift?.shiftDate ?? initialDateISO ?? '';

  const [pharmacies, setPharmacies] = useState<Pharmacy[]>([]);
  const [couriers, setCouriers] = useState<Courier[]>([]);
  const [institutions, setInstitutions] = useState<Institution[]>([]);

  const [selectedPharmacyIds, setSelectedPharmacyIds] = useState<string[]>(
    shift ? shift.pharmacyIds : (initialPharmacyId ? [initialPharmacyId] : []),
  );
  const [courierId, setCourierId] = useState<string>(shift?.courierId ?? ''); // '' = open
  const [shiftType, setShiftType] = useState<ShiftType>(shift?.shiftType ?? 'regular');
  const [transportMode, setTransportMode] = useState<TransportMode>(shift?.transportMode ?? 'bike');
  // null = nog niet bekend. Bewust géén stille default op 'bedrijfsauto': dan is
  // "niemand heeft ernaar gekeken" niet te onderscheiden van een echte keuze.
  const [carIsOwn, setCarIsOwn] = useState<boolean | null>(shift?.carIsOwn ?? null);
  const [startTime, setStartTime] = useState(shift?.startTime ?? '09:00');
  const [endTime, setEndTime] = useState(shift?.budgetedEndTime ?? '');
  const [selectedInstitutionIds, setSelectedInstitutionIds] = useState<string[]>(shift ? shift.institutionIds : []);
  const [description, setDescription] = useState(shift?.description ?? '');
  const [timingReliable, setTimingReliable] = useState(shift?.timingReliable ?? false);

  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const [conflictPrompt, setConflictPrompt] = useState<Shift[] | null>(null);

  const pharmacyName = useMemo(() => new Map(pharmacies.map((p) => [p.id, p.name])), [pharmacies]);

  // Referentiedata laden.
  useEffect(() => {
    (async () => {
      try {
        const [phs, crs] = await Promise.all([getPharmacies(), getCouriers()]);
        setPharmacies(phs);
        setCouriers(crs);
      } catch (e: any) {
        setError(e?.message ?? 'Laden mislukt.');
      }
    })();
  }, []);

  // Instellingen (her)laden zodra type = instelling én de apotheekselectie wijzigt.
  // De reconciliatie van geselecteerde instellingen gebeurt hier (binnen de load),
  // zodat een voorgevulde selectie in bewerkmodus niet gewist wordt vóór het laden.
  useEffect(() => {
    if (shiftType !== 'institution' || selectedPharmacyIds.length === 0) {
      setInstitutions([]);
      setSelectedInstitutionIds([]);
      return;
    }
    let cancelled = false;
    getInstitutions(selectedPharmacyIds)
      .then((list) => {
        if (cancelled) return;
        setInstitutions(list);
        // Selecties die niet meer bij de apotheekkeuze horen, deselecteren.
        setSelectedInstitutionIds((ids) => ids.filter((id) => list.some((i) => i.id === id)));
      })
      .catch(() => { if (!cancelled) setInstitutions([]); });
    return () => { cancelled = true; };
  }, [shiftType, selectedPharmacyIds]);

  // Alleen koeriers gekoppeld aan ≥1 van de gekozen apotheken (de vereniging).
  const eligibleCouriers = useMemo(
    () => couriers.filter((c) => c.pharmacyIds.some((pid) => selectedPharmacyIds.includes(pid))),
    [couriers, selectedPharmacyIds],
  );

  // Als de geselecteerde koerier niet langer in aanmerking komt: terug naar open.
  // Guard op couriers.length zodat een voorgevulde koerier niet gewist wordt
  // voordat de koerierslijst geladen is.
  useEffect(() => {
    if (couriers.length === 0) return;
    if (courierId && !eligibleCouriers.some((c) => c.id === courierId)) setCourierId('');
  }, [eligibleCouriers, courierId, couriers.length]);

  function togglePharmacy(id: string) {
    setSelectedPharmacyIds((ids) =>
      ids.includes(id) ? ids.filter((x) => x !== id) : [...ids, id],
    );
  }
  function toggleInstitution(id: string) {
    setSelectedInstitutionIds((ids) =>
      ids.includes(id) ? ids.filter((x) => x !== id) : [...ids, id],
    );
  }

  const showDescription = shiftType === 'other_transport' || shiftType === 'urgent';

  function buildPayload() {
    return {
      courierId: courierId || null,
      shiftType,
      shiftDate,
      startTime,
      budgetedEndTime: endTime || null,
      transportMode,
      carIsOwn: transportMode === 'car' ? carIsOwn : null,
      description: showDescription ? (description.trim() || null) : null,
      pharmacyIds: selectedPharmacyIds,
      institutionIds: shiftType === 'institution' ? selectedInstitutionIds : [],
      timingReliable,
    };
  }

  async function doSave() {
    setConflictPrompt(null);
    setSaving(true);
    try {
      if (isEdit) await updateShift(shift!.id, buildPayload());
      else await createShift(buildPayload());
      onSaved();
    } catch (err: any) {
      setError(err?.message ?? 'Opslaan mislukt.');
    } finally {
      setSaving(false);
    }
  }

  async function submit(e: FormEvent) {
    e.preventDefault();
    setError('');
    if (selectedPharmacyIds.length === 0) { setError('Kies minstens één apotheek.'); return; }
    if (!startTime) { setError('Vul een starttijd in.'); return; }

    // Harde tijdoverlap met een andere dienst van deze koerier op deze datum?
    if (courierId) {
      setSaving(true);
      try {
        const others = await getCourierShiftsOnDate(courierId, shiftDate, isEdit ? shift!.id : undefined);
        const probe: Shift = {
          id: 'nieuw', courierId, courierName: null, shiftType, shiftDate,
          startTime, budgetedEndTime: endTime || null, status: shift?.status ?? 'draft',
          transportMode, carIsOwn, description: null, pharmacyIds: selectedPharmacyIds,
          institutionIds: [], timingReliable, scheduleId: shift?.scheduleId ?? null,
        };
        const hard = others.filter((o) => pairLevel(probe, o) === 'hard');
        if (hard.length > 0) { setConflictPrompt(hard); setSaving(false); return; }
      } catch (err: any) {
        setError(err?.message ?? 'Conflictcheck mislukt.'); setSaving(false); return;
      }
    }
    await doSave();
  }

  return (
    <div className="fixed inset-0 z-50 bg-black/40 flex items-start justify-center p-4 overflow-y-auto" onClick={onClose}>
      <form
        onSubmit={submit}
        onClick={(e) => e.stopPropagation()}
        className="bg-white rounded-xl shadow-lg w-full max-w-lg my-8 p-5 space-y-4"
      >
        <div className="flex items-center justify-between">
          <h2 className="font-semibold text-slate-800">
            {isEdit ? 'Dienst bewerken' : 'Dienst toevoegen'} — {shiftDate}
          </h2>
          <button type="button" onClick={onClose} className="text-slate-400 hover:text-slate-700"><X size={18} /></button>
        </div>

        {/* Apotheken (multi-select) */}
        <fieldset>
          <legend className="text-sm font-medium mb-1">Apotheken</legend>
          <div className="max-h-32 overflow-y-auto border border-slate-200 rounded-lg p-2 space-y-1">
            {pharmacies.map((p) => (
              <label key={p.id} className="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={selectedPharmacyIds.includes(p.id)}
                  onChange={() => togglePharmacy(p.id)}
                />
                {p.name}
              </label>
            ))}
            {pharmacies.length === 0 && <p className="text-xs text-slate-400">Laden…</p>}
          </div>
          {selectedPharmacyIds.length > 1 && (
            <p className="text-xs text-slate-500 mt-1">Gedeelde dienst voor {selectedPharmacyIds.length} apotheken.</p>
          )}
        </fieldset>

        {/* Type */}
        <div>
          <label className="block text-sm font-medium mb-1">Type</label>
          <div className="flex flex-wrap gap-2">
            {SHIFT_TYPES.map((t) => (
              <button
                type="button" key={t}
                onClick={() => setShiftType(t)}
                className={[
                  'px-3 py-1.5 rounded-lg text-sm border',
                  shiftType === t
                    ? `${TYPE_STYLES[t].bg} ${TYPE_STYLES[t].text} ${TYPE_STYLES[t].border}`
                    : 'border-slate-300 text-slate-600 hover:bg-slate-50',
                ].join(' ')}
              >
                {TYPE_STYLES[t].label}
              </button>
            ))}
          </div>
        </div>

        {/* Koerier (optioneel) */}
        <div>
          <label className="block text-sm font-medium mb-1">Koerier <span className="text-slate-400 font-normal">(optioneel — leeg = open dienst)</span></label>
          <select
            value={courierId} onChange={(e) => setCourierId(e.target.value)}
            className="w-full border border-slate-300 rounded-lg px-3 py-2 text-sm"
          >
            <option value="">Open (nog niet toegewezen)</option>
            {eligibleCouriers.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
          {eligibleCouriers.length === 0 && (
            <p className="text-xs text-slate-400 mt-1">Geen koeriers gekoppeld aan de gekozen apotheek(en).</p>
          )}
        </div>

        {/* Vervoermiddel */}
        <div>
          <label className="block text-sm font-medium mb-1">Vervoermiddel</label>
          <div className="flex gap-2">
            {(['bike', 'car'] as TransportMode[]).map((m) => (
              <button
                type="button" key={m}
                onClick={() => {
                  setTransportMode(m);
                  // Terug naar fiets → keuze wissen, zodat een eerdere autokeuze
                  // niet blijft hangen en later ongemerkt weer opduikt.
                  if (m === 'bike') setCarIsOwn(null);
                }}
                className={[
                  'px-3 py-1.5 rounded-lg text-sm border',
                  transportMode === m ? 'bg-green-100 text-green-800 border-green-500' : 'border-slate-300 text-slate-600 hover:bg-slate-50',
                ].join(' ')}
              >
                {TRANSPORT_LABELS[m]}
              </button>
            ))}
          </div>

          {/* Alleen bij auto: van wie is de auto. 'Nog niet bekend' is een
              volwaardige keuze — bij inplannen is dat vaak nog niet duidelijk. */}
          {transportMode === 'car' && (
            <div className="mt-2">
              <label className="block text-sm font-medium mb-1">Auto</label>
              <div className="flex flex-wrap gap-2">
                {CAR_OWNER_OPTIONS.map((o) => (
                  <button
                    type="button" key={String(o.value)}
                    onClick={() => setCarIsOwn(o.value)}
                    className={[
                      'px-3 py-1.5 rounded-lg text-sm border',
                      carIsOwn === o.value
                        ? 'bg-green-100 text-green-800 border-green-500'
                        : 'border-slate-300 text-slate-600 hover:bg-slate-50',
                    ].join(' ')}
                  >
                    {o.label}
                  </button>
                ))}
              </div>
              {carIsOwn === null && (
                <p className="text-xs text-amber-600 mt-1">
                  Zonder keuze blijft de dienst gemarkeerd als "auto onbekend" in het overzicht.
                </p>
              )}
            </div>
          )}
        </div>

        {/* Tijden */}
        <div className="flex gap-4">
          <div className="flex-1">
            <label className="block text-sm font-medium mb-1">Starttijd</label>
            <input type="time" value={startTime} onChange={(e) => setStartTime(e.target.value)} required
              className="w-full border border-slate-300 rounded-lg px-3 py-2 text-sm" />
          </div>
          <div className="flex-1">
            <label className="block text-sm font-medium mb-1">Gebudgetteerde eindtijd <span className="text-slate-400 font-normal">(optioneel)</span></label>
            <input type="time" value={endTime} onChange={(e) => setEndTime(e.target.value)}
              className="w-full border border-slate-300 rounded-lg px-3 py-2 text-sm" />
          </div>
        </div>

        {/* Conditioneel: instellingen bij type 'instelling' */}
        {shiftType === 'institution' && (
          <fieldset>
            <legend className="text-sm font-medium mb-1">Instellingen (bestemmingen)</legend>
            <div className="max-h-32 overflow-y-auto border border-slate-200 rounded-lg p-2 space-y-1">
              {institutions.map((i) => (
                <label key={i.id} className="flex items-center gap-2 text-sm">
                  <input type="checkbox" checked={selectedInstitutionIds.includes(i.id)} onChange={() => toggleInstitution(i.id)} />
                  {i.name}
                </label>
              ))}
              {institutions.length === 0 && (
                <p className="text-xs text-slate-400">Geen actieve instellingen voor de gekozen apotheek(en).</p>
              )}
            </div>
          </fieldset>
        )}

        {/* Conditioneel: omschrijving bij overig transport / spoed */}
        {showDescription && (
          <div>
            <label className="block text-sm font-medium mb-1">Omschrijving</label>
            <textarea value={description} onChange={(e) => setDescription(e.target.value)} rows={2}
              className="w-full border border-slate-300 rounded-lg px-3 py-2 text-sm"
              placeholder="Korte omschrijving van de rit…" />
          </div>
        )}

        {/* Kalibratie-markering */}
        <label className="flex items-start gap-2 rounded-lg border border-slate-200 p-3 cursor-pointer">
          <input
            type="checkbox" checked={timingReliable}
            onChange={(e) => setTimingReliable(e.target.checked)}
            className="mt-0.5"
          />
          <span className="text-sm">
            <span className="font-medium">Bruikbaar voor kalibratie</span>
            <span className="block text-xs text-slate-500">
              Alleen aanvinken als dit een volledige, echte dienst is — van ophalen tot de laatste
              bezorging. Uitgevinkt laten bij testritten of onderbroken diensten; de berekende
              tijden tellen dan niet mee in de ijking.
            </span>
          </span>
        </label>

        {error && <p className="text-sm text-red-600">{error}</p>}

        <div className="flex justify-end gap-2 pt-1">
          <button type="button" onClick={onClose} className="px-4 py-2 text-sm text-slate-600 hover:text-slate-900">Annuleren</button>
          <button type="submit" disabled={saving}
            className="px-4 py-2 text-sm bg-green-600 hover:bg-green-700 disabled:opacity-60 text-white rounded-lg font-medium">
            {saving ? (isEdit ? 'Opslaan…' : 'Aanmaken…') : (isEdit ? 'Opslaan' : 'Aanmaken')}
          </button>
        </div>
      </form>

      {conflictPrompt && (
        <div className="fixed inset-0 z-10 bg-black/50 flex items-center justify-center p-4"
          onClick={(e) => { e.stopPropagation(); setConflictPrompt(null); }}>
          <div className="bg-white rounded-xl shadow-lg w-full max-w-sm p-5 space-y-3" onClick={(e) => e.stopPropagation()}>
            <div className="flex items-center gap-2 text-red-600">
              <AlertTriangle size={18} /><h3 className="font-semibold">Tijdconflict</h3>
            </div>
            <p className="text-sm text-slate-600">
              {couriers.find((c) => c.id === courierId)?.name ?? 'Deze koerier'} staat die dag al op
              {conflictPrompt.length === 1 ? ' een dienst die' : ` ${conflictPrompt.length} diensten die`} overlapt{conflictPrompt.length === 1 ? '' : 'en'}:
            </p>
            <ul className="text-sm list-disc list-inside text-slate-700">
              {conflictPrompt.map((o) => (
                <li key={o.id}>
                  {o.budgetedEndTime ? `${o.startTime}–${o.budgetedEndTime}` : o.startTime}
                  {o.pharmacyIds.length > 0 && ` (${o.pharmacyIds.map((id) => pharmacyName.get(id) ?? id).join(', ')})`}
                  {' — '}{o.status === 'draft' ? 'concept' : 'bevestigd'}
                </li>
              ))}
            </ul>
            {conflictPrompt.some((o) => o.status !== 'draft') && (
              <p className="text-sm text-amber-700">Minstens één is al bevestigd — de koerier is daarvoor al geïnformeerd.</p>
            )}
            <div className="flex justify-end gap-2">
              <button type="button" onClick={() => setConflictPrompt(null)}
                className="px-4 py-2 text-sm text-slate-600 hover:text-slate-900">Annuleren</button>
              <button type="button" onClick={doSave}
                className="px-4 py-2 text-sm bg-green-600 hover:bg-green-700 text-white rounded-lg font-medium">
                Toch {isEdit ? 'opslaan' : 'aanmaken'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
