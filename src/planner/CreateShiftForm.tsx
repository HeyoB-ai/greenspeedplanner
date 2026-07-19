import { FormEvent, useEffect, useMemo, useState } from 'react';
import { X } from 'lucide-react';
import { Courier, Institution, Pharmacy, ShiftType, TransportMode } from '../types';
import { createShift, getCouriers, getInstitutions, getPharmacies } from './plannerService';
import { SHIFT_TYPES, TRANSPORT_LABELS, TYPE_STYLES } from './constants';

interface Props {
  initialPharmacyId: string;
  initialDateISO: string;
  onClose: () => void;
  onCreated: () => void;
}

export default function CreateShiftForm({ initialPharmacyId, initialDateISO, onClose, onCreated }: Props) {
  const [pharmacies, setPharmacies] = useState<Pharmacy[]>([]);
  const [couriers, setCouriers] = useState<Courier[]>([]);
  const [institutions, setInstitutions] = useState<Institution[]>([]);

  const [selectedPharmacyIds, setSelectedPharmacyIds] = useState<string[]>([initialPharmacyId]);
  const [courierId, setCourierId] = useState<string>('');       // '' = open
  const [shiftType, setShiftType] = useState<ShiftType>('regular');
  const [transportMode, setTransportMode] = useState<TransportMode>('bike');
  const [startTime, setStartTime] = useState('09:00');
  const [endTime, setEndTime] = useState('');
  const [selectedInstitutionIds, setSelectedInstitutionIds] = useState<string[]>([]);
  const [description, setDescription] = useState('');

  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);

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
  useEffect(() => {
    if (shiftType !== 'institution' || selectedPharmacyIds.length === 0) {
      setInstitutions([]);
      return;
    }
    let cancelled = false;
    getInstitutions(selectedPharmacyIds)
      .then((list) => { if (!cancelled) setInstitutions(list); })
      .catch(() => { if (!cancelled) setInstitutions([]); });
    return () => { cancelled = true; };
  }, [shiftType, selectedPharmacyIds]);

  // Alleen koeriers gekoppeld aan ≥1 van de gekozen apotheken (de vereniging).
  const eligibleCouriers = useMemo(
    () => couriers.filter((c) => c.pharmacyIds.some((pid) => selectedPharmacyIds.includes(pid))),
    [couriers, selectedPharmacyIds],
  );

  // Als de geselecteerde koerier niet langer in aanmerking komt: terug naar open.
  useEffect(() => {
    if (courierId && !eligibleCouriers.some((c) => c.id === courierId)) setCourierId('');
  }, [eligibleCouriers, courierId]);

  // Instellingen die niet meer bij de apotheekselectie horen, deselecteren.
  useEffect(() => {
    setSelectedInstitutionIds((ids) => ids.filter((id) => institutions.some((i) => i.id === id)));
  }, [institutions]);

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

  async function submit(e: FormEvent) {
    e.preventDefault();
    setError('');
    if (selectedPharmacyIds.length === 0) { setError('Kies minstens één apotheek.'); return; }
    if (!startTime) { setError('Vul een starttijd in.'); return; }

    setSaving(true);
    try {
      await createShift({
        courierId: courierId || null,
        shiftType,
        shiftDate: initialDateISO,
        startTime,
        budgetedEndTime: endTime || null,
        transportMode,
        description: showDescription ? (description.trim() || null) : null,
        pharmacyIds: selectedPharmacyIds,
        institutionIds: shiftType === 'institution' ? selectedInstitutionIds : [],
      });
      onCreated();
    } catch (err: any) {
      setError(err?.message ?? 'Opslaan mislukt.');
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="fixed inset-0 bg-black/40 flex items-start justify-center p-4 overflow-y-auto" onClick={onClose}>
      <form
        onSubmit={submit}
        onClick={(e) => e.stopPropagation()}
        className="bg-white rounded-xl shadow-lg w-full max-w-lg my-8 p-5 space-y-4"
      >
        <div className="flex items-center justify-between">
          <h2 className="font-semibold text-slate-800">Nieuwe dienst — {initialDateISO}</h2>
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
                onClick={() => setTransportMode(m)}
                className={[
                  'px-3 py-1.5 rounded-lg text-sm border',
                  transportMode === m ? 'bg-green-100 text-green-800 border-green-500' : 'border-slate-300 text-slate-600 hover:bg-slate-50',
                ].join(' ')}
              >
                {TRANSPORT_LABELS[m]}
              </button>
            ))}
          </div>
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

        {error && <p className="text-sm text-red-600">{error}</p>}

        <div className="flex justify-end gap-2 pt-1">
          <button type="button" onClick={onClose} className="px-4 py-2 text-sm text-slate-600 hover:text-slate-900">Annuleren</button>
          <button type="submit" disabled={saving}
            className="px-4 py-2 text-sm bg-green-600 hover:bg-green-700 disabled:opacity-60 text-white rounded-lg font-medium">
            {saving ? 'Opslaan…' : 'Dienst opslaan'}
          </button>
        </div>
      </form>
    </div>
  );
}
