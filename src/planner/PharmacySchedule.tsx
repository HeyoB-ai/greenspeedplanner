import { FormEvent, useEffect, useMemo, useState } from 'react';
import { AlertTriangle, Pencil, Plus, Power, X } from 'lucide-react';
import { Courier, ScheduleLine, ScheduleLineInput, TransportMode } from '../types';
import { getCouriers } from './plannerService';
import { createSchedule, deactivateSchedule, getSchedules, updateSchedule } from './scheduleService';
import { TRANSPORT_LABELS, WEEKDAY_LABELS, WEEKDAY_LABELS_LONG, carOwnerLabel } from './constants';

interface Props {
  pharmacyId: string;
  pharmacyName: string;
  onClose: () => void;
  onChanged: () => void; // week herladen na een roosterwijziging
}

const emptyForm = (pharmacyId: string): ScheduleLineInput => ({
  pharmacyId,
  weekday: 1,
  startTime: '09:00',
  budgetedEndTime: null,
  courierId: null,
  transportMode: 'bike',
  carIsOwn: null,
  startDate: new Date().toISOString().slice(0, 10),
  endDate: null,
});

export default function PharmacySchedule({ pharmacyId, pharmacyName, onClose, onChanged }: Props) {
  const [lines, setLines] = useState<ScheduleLine[]>([]);
  const [couriers, setCouriers] = useState<Courier[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);

  // Formulierstate: null = geen formulier open; anders create/edit.
  const [form, setForm] = useState<ScheduleLineInput | null>(null);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [originalWeekday, setOriginalWeekday] = useState<number | null>(null);

  async function reload() {
    setLoading(true);
    try {
      const [ls, cs] = await Promise.all([getSchedules(pharmacyId), getCouriers()]);
      setLines(ls);
      setCouriers(cs);
      setError('');
    } catch (e: any) {
      setError(e?.message ?? 'Laden mislukt.');
    } finally {
      setLoading(false);
    }
  }
  useEffect(() => { reload(); /* eslint-disable-next-line */ }, [pharmacyId]);

  const eligibleCouriers = useMemo(
    () => couriers.filter((c) => c.pharmacyIds.includes(pharmacyId)),
    [couriers, pharmacyId],
  );
  const courierName = useMemo(() => new Map(couriers.map((c) => [c.id, c.name])), [couriers]);

  function openCreate() { setEditingId(null); setOriginalWeekday(null); setForm(emptyForm(pharmacyId)); }
  function openEdit(l: ScheduleLine) {
    setEditingId(l.id);
    setOriginalWeekday(l.weekday);
    setForm({
      pharmacyId, weekday: l.weekday, startTime: l.startTime, budgetedEndTime: l.budgetedEndTime,
      courierId: l.courierId, transportMode: l.transportMode, carIsOwn: l.carIsOwn,
      startDate: l.startDate, endDate: l.endDate,
    });
  }

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (!form) return;
    setError('');
    if (!form.startTime) { setError('Vul een starttijd in.'); return; }
    // Geen blokkade meer op een ontbrekende autokeuze: sinds migratie 013 is
    // "nog niet bekend" een geldige stand. De markering in het overzicht houdt
    // het zichtbaar.

    setSaving(true);
    try {
      if (editingId) await updateSchedule(editingId, form);
      else await createSchedule(form);
      setForm(null); setEditingId(null);
      await reload();
      onChanged();
    } catch (err: any) {
      setError(err?.message ?? 'Opslaan mislukt.');
    } finally {
      setSaving(false);
    }
  }

  async function deactivate(l: ScheduleLine) {
    setSaving(true);
    setError('');
    try {
      await deactivateSchedule(l.id);
      await reload();
      onChanged();
    } catch (err: any) {
      setError(err?.message ?? 'Deactiveren mislukt.');
    } finally {
      setSaving(false);
    }
  }

  const weekdayChanged = editingId !== null && form !== null && originalWeekday !== null && form.weekday !== originalWeekday;

  return (
    <div className="fixed inset-0 bg-black/40 flex items-start justify-center p-4 overflow-y-auto" onClick={onClose}>
      <div className="bg-white rounded-xl shadow-lg w-full max-w-2xl my-8" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between px-5 py-3 border-b border-slate-200">
          <h2 className="font-semibold text-slate-800">Rooster — {pharmacyName}</h2>
          <button onClick={onClose} className="text-slate-400 hover:text-slate-700"><X size={18} /></button>
        </div>

        <div className="p-5 space-y-4">
          {error && <p className="text-sm text-red-600">{error}</p>}
          {loading && <p className="text-sm text-slate-500">Laden…</p>}

          {/* Bestaande regels */}
          {!loading && lines.length === 0 && (
            <p className="text-sm text-slate-500">Nog geen roosterregels voor deze apotheek.</p>
          )}
          <ul className="divide-y divide-slate-100">
            {lines.map((l) => (
              <li key={l.id} className={`flex items-center justify-between py-2 text-sm ${l.isActive ? '' : 'opacity-50'}`}>
                <div>
                  <span className="font-medium">{WEEKDAY_LABELS_LONG[l.weekday - 1]}</span>
                  {' · '}{l.startTime}{l.budgetedEndTime ? `–${l.budgetedEndTime}` : ''}
                  {' · '}{l.courierId ? (courierName.get(l.courierId) ?? 'Koerier') : 'Open'}
                  {' · '}{TRANSPORT_LABELS[l.transportMode]}
                  {l.transportMode === 'car' && (
                    <span className={l.carIsOwn === null ? 'text-amber-600' : 'text-slate-500'}>
                      {' '}({carOwnerLabel(l.carIsOwn)})
                    </span>
                  )}
                  <span className="block text-xs text-slate-400">
                    vanaf {l.startDate}{l.endDate ? ` t/m ${l.endDate}` : ''}{l.isActive ? '' : ' · inactief'}
                  </span>
                </div>
                {l.isActive && (
                  <div className="flex items-center gap-3 shrink-0">
                    <button onClick={() => openEdit(l)} className="inline-flex items-center gap-1 text-slate-600 hover:text-slate-900">
                      <Pencil size={14} /> Bewerken
                    </button>
                    <button onClick={() => deactivate(l)} disabled={saving} className="inline-flex items-center gap-1 text-amber-700 hover:text-amber-800">
                      <Power size={14} /> Deactiveren
                    </button>
                  </div>
                )}
              </li>
            ))}
          </ul>

          {!form && (
            <button onClick={openCreate} className="inline-flex items-center gap-1 text-sm text-green-700 hover:text-green-800 font-medium">
              <Plus size={15} /> Nieuwe roosterregel
            </button>
          )}

          {/* Formulier */}
          {form && (
            <form onSubmit={submit} className="rounded-lg border border-slate-200 p-4 space-y-3 bg-slate-50">
              <div className="grid grid-cols-2 gap-3">
                <label className="text-sm">
                  <span className="block font-medium mb-1">Weekdag</span>
                  <select value={form.weekday} onChange={(e) => setForm({ ...form, weekday: Number(e.target.value) })}
                    className="w-full border border-slate-300 rounded-lg px-2 py-1.5 bg-white">
                    {WEEKDAY_LABELS.map((lbl, i) => <option key={i} value={i + 1}>{lbl}</option>)}
                  </select>
                </label>
                <label className="text-sm">
                  <span className="block font-medium mb-1">Koerier <span className="text-slate-400 font-normal">(leeg = open)</span></span>
                  <select value={form.courierId ?? ''} onChange={(e) => setForm({ ...form, courierId: e.target.value || null })}
                    className="w-full border border-slate-300 rounded-lg px-2 py-1.5 bg-white">
                    <option value="">Open (geen vaste koerier)</option>
                    {eligibleCouriers.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
                  </select>
                  {eligibleCouriers.length === 0 && (
                    <span className="block text-xs text-amber-600 mt-1">
                      Geen gekoppelde koeriers — laat een koerier eerst een code invoeren voor deze apotheek.
                    </span>
                  )}
                </label>
                <label className="text-sm">
                  <span className="block font-medium mb-1">Starttijd</span>
                  <input type="time" value={form.startTime} onChange={(e) => setForm({ ...form, startTime: e.target.value })} required
                    className="w-full border border-slate-300 rounded-lg px-2 py-1.5 bg-white" />
                </label>
                <label className="text-sm">
                  <span className="block font-medium mb-1">Gebudg. eindtijd <span className="text-slate-400 font-normal">(optioneel)</span></span>
                  <input type="time" value={form.budgetedEndTime ?? ''} onChange={(e) => setForm({ ...form, budgetedEndTime: e.target.value || null })}
                    className="w-full border border-slate-300 rounded-lg px-2 py-1.5 bg-white" />
                </label>
                <label className="text-sm">
                  <span className="block font-medium mb-1">Vervoermiddel</span>
                  <select value={form.transportMode}
                    onChange={(e) => {
                      const m = e.target.value as TransportMode;
                      // Bij auto de bestaande keuze behouden, anders null (= nog
                      // niet bekend). Géén stille terugval op 'bedrijfsauto':
                      // dat maakt een gok ononderscheidbaar van een keuze.
                      setForm({ ...form, transportMode: m, carIsOwn: m === 'car' ? form.carIsOwn : null });
                    }}
                    className="w-full border border-slate-300 rounded-lg px-2 py-1.5 bg-white">
                    <option value="bike">{TRANSPORT_LABELS.bike}</option>
                    <option value="car">{TRANSPORT_LABELS.car}</option>
                  </select>
                </label>
                {form.transportMode === 'car' && (
                  <label className="text-sm">
                    <span className="block font-medium mb-1">Auto</span>
                    <select value={form.carIsOwn === null ? 'unknown' : form.carIsOwn ? 'own' : 'company'}
                      onChange={(e) => setForm({
                        ...form,
                        carIsOwn: e.target.value === 'unknown' ? null : e.target.value === 'own',
                      })}
                      className="w-full border border-slate-300 rounded-lg px-2 py-1.5 bg-white">
                      <option value="own">Eigen auto</option>
                      <option value="company">Bedrijfsauto</option>
                      <option value="unknown">Nog niet bekend</option>
                    </select>
                    {form.carIsOwn === null && (
                      <span className="block text-xs text-amber-600 mt-1">
                        Diensten uit deze regel komen binnen met "auto onbekend".
                      </span>
                    )}
                  </label>
                )}
                <label className="text-sm">
                  <span className="block font-medium mb-1">Begindatum</span>
                  <input type="date" value={form.startDate} onChange={(e) => setForm({ ...form, startDate: e.target.value })} required
                    className="w-full border border-slate-300 rounded-lg px-2 py-1.5 bg-white" />
                </label>
                <label className="text-sm">
                  <span className="block font-medium mb-1">Einddatum <span className="text-slate-400 font-normal">(optioneel)</span></span>
                  <input type="date" value={form.endDate ?? ''} onChange={(e) => setForm({ ...form, endDate: e.target.value || null })}
                    className="w-full border border-slate-300 rounded-lg px-2 py-1.5 bg-white" />
                </label>
              </div>

              {weekdayChanged && (
                <p className="flex items-start gap-1.5 text-xs text-amber-700">
                  <AlertTriangle size={14} className="mt-0.5 shrink-0" />
                  Weekdag gewijzigd: eerder overgeslagen datums (vakantie/feestdag) op de oude weekdag gelden
                  niet automatisch voor de nieuwe weekdag — controleer die opnieuw.
                </p>
              )}

              <div className="flex justify-end gap-2">
                <button type="button" onClick={() => { setForm(null); setEditingId(null); }} className="px-3 py-1.5 text-sm text-slate-600 hover:text-slate-900">
                  Annuleren
                </button>
                <button type="submit" disabled={saving}
                  className="px-4 py-1.5 text-sm bg-green-600 hover:bg-green-700 disabled:opacity-60 text-white rounded-lg font-medium">
                  {saving ? 'Opslaan…' : editingId ? 'Opslaan' : 'Toevoegen'}
                </button>
              </div>
            </form>
          )}

          <p className="text-xs text-slate-400">
            Wijzigingen gelden alleen voor toekomstige concepten; bevestigde diensten blijven ongemoeid.
            Gegenereerde diensten komen binnen als concept en volgen de bevestig-flow.
          </p>
        </div>
      </div>
    </div>
  );
}
