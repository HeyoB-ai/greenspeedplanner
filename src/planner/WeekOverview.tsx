import { useEffect, useMemo, useState } from 'react';
import { CheckCircle2, ChevronLeft, ChevronRight, Plus } from 'lucide-react';
import { Courier, Pharmacy, Shift } from '../types';
import { confirmShifts, getInstitutions, getPharmacies, getCouriers, getShiftsForWeek } from './plannerService';
import {
  addDays, formatDayHeader, isoWeekNumber, startOfWeek, toISODate, weekDays,
} from './dates';
import { SHIFT_TYPES, TYPE_STYLES, WEEKDAY_LABELS } from './constants';
import ShiftChip from './ShiftChip';
import DayView from './DayView';

type CourierFilter = 'all' | 'open' | string;

interface Props {
  // Wordt aangeroepen als de planner op een cel klikt om een dienst aan te maken.
  onCreate: (pharmacyId: string, dateISO: string) => void;
  // Bewerk-/verwijderacties ontstaan in DayView (die hier via een early return
  // gerenderd wordt). We tillen DayView NIET naar App; in plaats daarvan geven we
  // deze callbacks door WeekOverview heen naar App, dat de modals + het
  // refreshSignal beheert. Zo blijft alle weekdata (shifts, namen) hier lokaal.
  onEdit: (shift: Shift) => void;
  onDelete: (shift: Shift) => void;
  // Klik op een apotheek in de linkerkolom → roosterscherm.
  onOpenSchedule: (pharmacy: { id: string; name: string }) => void;
  // Bevestigen (concept → planned) handelen we hier lokaal af, want alle
  // weekdata zit hier. Na afloop trigger deze callback het refreshSignal in App.
  onChanged: () => void;
  // Verhoog dit getal na een succesvolle mutatie → herlaadt de week.
  refreshSignal: number;
}

export default function WeekOverview({ onCreate, onEdit, onDelete, onOpenSchedule, onChanged, refreshSignal }: Props) {
  const [weekStart, setWeekStart] = useState(() => startOfWeek(new Date()));
  const [pharmacies, setPharmacies] = useState<Pharmacy[]>([]);
  const [couriers, setCouriers] = useState<Courier[]>([]);
  const [shifts, setShifts] = useState<Shift[]>([]);
  const [institutionNames, setInstitutionNames] = useState<Map<string, string>>(new Map());
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  const [pharmacyFilter, setPharmacyFilter] = useState('');
  const [courierFilter, setCourierFilter] = useState<CourierFilter>('all');
  const [onlyWithShifts, setOnlyWithShifts] = useState(false);
  const [onlyDrafts, setOnlyDrafts] = useState(false);
  const [draftKind, setDraftKind] = useState<'all' | 'manual' | 'schedule'>('all');
  const [selectedDay, setSelectedDay] = useState<Date | null>(null);
  const [showBulkConfirm, setShowBulkConfirm] = useState(false);
  const [confirmBusy, setConfirmBusy] = useState(false);

  const days = useMemo(() => weekDays(weekStart), [weekStart]);
  const weekStartISO = toISODate(weekStart);
  const weekEndISO = toISODate(addDays(weekStart, 6));

  // Referentiedata één keer laden.
  useEffect(() => {
    (async () => {
      try {
        const [phs, crs] = await Promise.all([getPharmacies(), getCouriers()]);
        setPharmacies(phs);
        setCouriers(crs);
        const insts = await getInstitutions(phs.map((p) => p.id));
        setInstitutionNames(new Map(insts.map((i) => [i.id, i.name])));
      } catch (e: any) {
        setError(e?.message ?? 'Laden van referentiedata mislukt.');
      }
    })();
  }, []);

  // Diensten van de week (her)laden.
  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    getShiftsForWeek(weekStartISO, weekEndISO)
      .then((rows) => { if (!cancelled) { setShifts(rows); setError(''); } })
      .catch((e) => { if (!cancelled) setError(e?.message ?? 'Laden van diensten mislukt.'); })
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [weekStartISO, weekEndISO, refreshSignal]);

  const passesCourierFilter = (s: Shift): boolean => {
    if (courierFilter === 'all') return true;
    if (courierFilter === 'open') return !s.courierId;
    return s.courierId === courierFilter;
  };

  const passesDraftKind = (s: Shift): boolean => {
    if (draftKind === 'all') return true;
    if (draftKind === 'schedule') return !!s.scheduleId;
    return !s.scheduleId; // 'manual'
  };
  const passesFilters = (s: Shift): boolean =>
    passesCourierFilter(s) && (!onlyDrafts || s.status === 'draft') && passesDraftKind(s);

  // shiftsByPharmacyDay[pharmacyId][dateISO] = Shift[]
  const grid = useMemo(() => {
    const map = new Map<string, Map<string, Shift[]>>();
    for (const s of shifts) {
      if (!passesFilters(s)) continue;
      for (const pid of s.pharmacyIds) {
        if (!map.has(pid)) map.set(pid, new Map());
        const byDay = map.get(pid)!;
        const list = byDay.get(s.shiftDate) ?? [];
        list.push(s);
        byDay.set(s.shiftDate, list);
      }
    }
    return map;
  }, [shifts, courierFilter, onlyDrafts, draftKind]);

  // Onbevestigde diensten in de zichtbare week (los van de cel-filters).
  const weekDrafts = useMemo(() => shifts.filter((s) => s.status === 'draft'), [shifts]);
  const scheduleDraftCount = useMemo(() => weekDrafts.filter((s) => s.scheduleId).length, [weekDrafts]);
  const manualDraftCount = weekDrafts.length - scheduleDraftCount;
  const draftPeriod = useMemo(() => {
    if (weekDrafts.length === 0) return null;
    const ds = weekDrafts.map((s) => s.shiftDate).sort();
    return { from: ds[0], to: ds[ds.length - 1] };
  }, [weekDrafts]);

  async function handleConfirm(ids: string[]) {
    if (ids.length === 0) return;
    setConfirmBusy(true);
    setError('');
    try {
      await confirmShifts(ids);
      onChanged();
    } catch (e: any) {
      setError(e?.message ?? 'Bevestigen mislukt.');
    } finally {
      setConfirmBusy(false);
      setShowBulkConfirm(false);
    }
  }

  const pharmacyName = useMemo(
    () => new Map(pharmacies.map((p) => [p.id, p.name])),
    [pharmacies],
  );

  const visiblePharmacies = useMemo(() => {
    let list = pharmacies;
    if (pharmacyFilter) list = list.filter((p) => p.id === pharmacyFilter);
    if (onlyWithShifts) list = list.filter((p) => (grid.get(p.id)?.size ?? 0) > 0);
    return list;
  }, [pharmacies, pharmacyFilter, onlyWithShifts, grid]);

  if (selectedDay) {
    const dayISO = toISODate(selectedDay);
    const dayShifts = shifts.filter((s) => s.shiftDate === dayISO && passesFilters(s));
    return (
      <DayView
        date={selectedDay}
        shifts={dayShifts}
        pharmacyNames={pharmacyName}
        institutionNames={institutionNames}
        onBack={() => setSelectedDay(null)}
        onEdit={onEdit}
        onDelete={onDelete}
        onConfirm={(s) => handleConfirm([s.id])}
      />
    );
  }

  return (
    <div className="p-4 space-y-4">
      {/* Weeknavigatie */}
      <div className="flex items-center gap-3">
        <button
          onClick={() => setWeekStart(addDays(weekStart, -7))}
          className="p-1.5 rounded-lg border border-slate-300 hover:bg-slate-100" aria-label="Vorige week"
        >
          <ChevronLeft size={18} />
        </button>
        <div className="font-semibold">
          Week {isoWeekNumber(weekStart)}
          <span className="ml-2 text-sm font-normal text-slate-500">
            {formatDayHeader(weekStart)} – {formatDayHeader(addDays(weekStart, 6))}
          </span>
        </div>
        <button
          onClick={() => setWeekStart(addDays(weekStart, 7))}
          className="p-1.5 rounded-lg border border-slate-300 hover:bg-slate-100" aria-label="Volgende week"
        >
          <ChevronRight size={18} />
        </button>
        <button
          onClick={() => setWeekStart(startOfWeek(new Date()))}
          className="ml-1 text-sm text-slate-600 hover:text-slate-900 underline"
        >
          Deze week
        </button>

        {/* Concept-teller + bulk bevestigen (zichtbare week) */}
        <div className="ml-auto flex items-center gap-3">
          <span className="text-sm text-slate-500">
            {weekDrafts.length} concept{weekDrafts.length === 1 ? '' : 'en'} onbevestigd
            {weekDrafts.length > 0 && (
              <span className="text-slate-400"> ({scheduleDraftCount} rooster · {manualDraftCount} handmatig)</span>
            )}
          </span>
          <button
            onClick={() => setShowBulkConfirm(true)}
            disabled={weekDrafts.length === 0}
            className="inline-flex items-center gap-1 text-sm rounded-lg border border-green-600 text-green-700 px-2.5 py-1 hover:bg-green-50 disabled:opacity-40 disabled:hover:bg-transparent"
          >
            <CheckCircle2 size={15} /> Bevestig concepten
          </button>
        </div>
      </div>

      {/* Filters */}
      <div className="flex flex-wrap items-center gap-3 text-sm">
        <label className="flex items-center gap-1.5">
          <span className="text-slate-500">Apotheek</span>
          <select
            value={pharmacyFilter} onChange={(e) => setPharmacyFilter(e.target.value)}
            className="border border-slate-300 rounded-lg px-2 py-1"
          >
            <option value="">Alle</option>
            {pharmacies.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
          </select>
        </label>
        <label className="flex items-center gap-1.5">
          <span className="text-slate-500">Koerier</span>
          <select
            value={courierFilter} onChange={(e) => setCourierFilter(e.target.value)}
            className="border border-slate-300 rounded-lg px-2 py-1"
          >
            <option value="all">Alle</option>
            <option value="open">Open (niet toegewezen)</option>
            {couriers.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
          </select>
        </label>
        <label className="flex items-center gap-1.5 cursor-pointer">
          <input type="checkbox" checked={onlyWithShifts} onChange={(e) => setOnlyWithShifts(e.target.checked)} />
          <span>Alleen apotheken met diensten deze week</span>
        </label>
        <label className="flex items-center gap-1.5 cursor-pointer">
          <input type="checkbox" checked={onlyDrafts} onChange={(e) => setOnlyDrafts(e.target.checked)} />
          <span>Alleen concepten</span>
        </label>
        <label className="flex items-center gap-1.5">
          <span className="text-slate-500">Herkomst</span>
          <select value={draftKind} onChange={(e) => setDraftKind(e.target.value as any)}
            className="border border-slate-300 rounded-lg px-2 py-1">
            <option value="all">Alle</option>
            <option value="manual">Alleen handmatig</option>
            <option value="schedule">Alleen rooster</option>
          </select>
        </label>
      </div>

      {/* Legenda */}
      <div className="flex flex-wrap items-center gap-4 text-xs text-slate-600">
        {SHIFT_TYPES.map((t) => (
          <span key={t} className="inline-flex items-center gap-1.5">
            <span className={`inline-block w-3 h-3 rounded ${TYPE_STYLES[t].swatch}`} />
            {TYPE_STYLES[t].label}
          </span>
        ))}
        <span className="inline-flex items-center gap-1.5">
          <span className="inline-block w-3 h-3 rounded border-2 border-dashed border-slate-400" />
          Open dienst
        </span>
      </div>

      {error && <p className="text-sm text-red-600">{error}</p>}
      {loading && <p className="text-sm text-slate-500">Diensten laden…</p>}

      {/* Raster */}
      <div className="overflow-x-auto border border-slate-200 rounded-lg">
        <table className="w-full border-collapse text-sm">
          <thead>
            <tr className="bg-slate-50">
              <th className="sticky left-0 z-10 bg-slate-50 text-left font-semibold px-3 py-2 border-b border-slate-200 min-w-[160px]">
                Apotheek
              </th>
              {days.map((d, i) => (
                <th key={i} className="px-2 py-2 border-b border-l border-slate-200 min-w-[130px]">
                  <button
                    onClick={() => setSelectedDay(d)}
                    className="w-full hover:text-green-700"
                    title="Klik voor dagweergave"
                  >
                    <div className="font-semibold">{WEEKDAY_LABELS[i]}</div>
                    <div className="text-xs font-normal text-slate-500">{formatDayHeader(d)}</div>
                  </button>
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {visiblePharmacies.map((p) => (
              <tr key={p.id} className="align-top">
                <td className="sticky left-0 z-10 bg-white px-3 py-2 border-b border-slate-200 font-medium">
                  <button
                    onClick={() => onOpenSchedule({ id: p.id, name: p.name })}
                    className="text-left hover:text-green-700 hover:underline"
                    title="Rooster beheren"
                  >
                    {p.name}
                  </button>
                </td>
                {days.map((d, i) => {
                  const dayISO = toISODate(d);
                  const cellShifts = grid.get(p.id)?.get(dayISO) ?? [];
                  return (
                    <td key={i} className="px-1.5 py-1.5 border-b border-l border-slate-200">
                      {cellShifts.length === 0 ? (
                        <button
                          onClick={() => onCreate(p.id, dayISO)}
                          className="w-full h-9 rounded-md border border-dashed border-slate-200 text-slate-300 hover:border-green-400 hover:text-green-500 flex items-center justify-center"
                          title="Dienst toevoegen"
                        >
                          <Plus size={14} />
                        </button>
                      ) : (
                        <div className="space-y-1">
                          {cellShifts.map((s) => (
                            <ShiftChip key={s.id} shift={s} onClick={() => setSelectedDay(d)} />
                          ))}
                          <button
                            onClick={() => onCreate(p.id, dayISO)}
                            className="w-full text-[11px] text-slate-400 hover:text-green-600 flex items-center justify-center gap-0.5 py-0.5"
                          >
                            <Plus size={11} /> dienst
                          </button>
                        </div>
                      )}
                    </td>
                  );
                })}
              </tr>
            ))}
            {visiblePharmacies.length === 0 && !loading && (
              <tr>
                <td colSpan={8} className="px-3 py-6 text-center text-slate-400">
                  Geen apotheken om te tonen.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      {/* Bulk-bevestiging van alle concepten in de zichtbare week */}
      {showBulkConfirm && (
        <div
          className="fixed inset-0 bg-black/40 flex items-center justify-center p-4"
          onClick={() => !confirmBusy && setShowBulkConfirm(false)}
        >
          <div className="bg-white rounded-xl shadow-lg w-full max-w-sm p-5 space-y-4" onClick={(e) => e.stopPropagation()}>
            <div className="flex items-center gap-2 text-green-700">
              <CheckCircle2 size={18} />
              <h2 className="font-semibold">Concepten bevestigen</h2>
            </div>
            <p className="text-sm text-slate-600">
              Je staat op het punt <strong>{weekDrafts.length} concept{weekDrafts.length === 1 ? '' : 'en'}</strong> te
              bevestigen ({scheduleDraftCount} uit rooster · {manualDraftCount} handmatig)
              {draftPeriod && <>, van <strong>{draftPeriod.from}</strong> t/m <strong>{draftPeriod.to}</strong></>}.
              Ze worden daarna zichtbaar voor de koeriers. Dit kan niet worden teruggedraaid.
            </p>
            <div className="flex justify-end gap-2">
              <button
                type="button" disabled={confirmBusy}
                onClick={() => setShowBulkConfirm(false)}
                className="px-4 py-2 text-sm text-slate-600 hover:text-slate-900 disabled:opacity-60"
              >
                Annuleren
              </button>
              <button
                type="button" disabled={confirmBusy}
                onClick={() => handleConfirm(weekDrafts.map((s) => s.id))}
                className="px-4 py-2 text-sm bg-green-600 hover:bg-green-700 disabled:opacity-60 text-white rounded-lg font-medium"
              >
                {confirmBusy ? 'Bevestigen…' : `Bevestig ${weekDrafts.length}`}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
