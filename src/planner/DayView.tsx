import { AlertTriangle, ArrowLeft, Bike, Car, CheckCircle2, MapPin, Pencil, Trash2, UserCircle2, Users } from 'lucide-react';
import { Shift } from '../types';
import { ConflictOther, ShiftConflict } from './conflicts';
import { TRANSPORT_LABELS, TYPE_STYLES, WEEKDAY_LABELS_LONG } from './constants';

interface Props {
  date: Date;
  shifts: Shift[];
  pharmacyNames: Map<string, string>;
  institutionNames: Map<string, string>;
  onBack: () => void;
  onEdit: (shift: Shift) => void;
  onDelete: (shift: Shift) => void;
  onConfirm: (shift: Shift) => void;
  conflicts: Map<string, ShiftConflict>;
}

// Ingezoomde dagweergave met meer detail per dienst.
export default function DayView({ date, shifts, pharmacyNames, institutionNames, onBack, onEdit, onDelete, onConfirm, conflicts }: Props) {
  const describeOther = (o: ConflictOther) => {
    const time = o.endTime ? `${o.startTime}–${o.endTime}` : o.startTime;
    const phs = o.pharmacyIds.map((id) => pharmacyNames.get(id) ?? id).join(', ');
    return `${time}${phs ? ` (${phs})` : ''} — ${o.status === 'draft' ? 'concept' : 'bevestigd'}`;
  };
  const dow = (date.getDay() + 6) % 7;
  const heading = `${WEEKDAY_LABELS_LONG[dow]} ${date.getDate()}-${date.getMonth() + 1}-${date.getFullYear()}`;

  return (
    <div className="max-w-3xl mx-auto p-4">
      <button onClick={onBack} className="inline-flex items-center gap-1 text-sm text-slate-600 hover:text-slate-900 mb-3">
        <ArrowLeft size={16} /> Terug naar week
      </button>
      <h2 className="text-lg font-semibold mb-3">{heading}</h2>

      {shifts.length === 0 && (
        <p className="text-sm text-slate-500">Geen diensten op deze dag.</p>
      )}

      <div className="space-y-2">
        {shifts.map((s) => {
          const style = TYPE_STYLES[s.shiftType];
          const isOpen = !s.courierId;
          const TransportIcon = s.transportMode === 'car' ? Car : Bike;
          const time = s.budgetedEndTime ? `${s.startTime}–${s.budgetedEndTime}` : s.startTime;
          const isDraft = s.status === 'draft';
          const conflict = conflicts.get(s.id);
          return (
            <div key={s.id} className={`rounded-lg border ${style.border} bg-white p-3 ${isDraft ? 'border-dashed' : ''}`}>
              <div className="flex items-center justify-between">
                <span className={`inline-flex items-center gap-2 text-sm font-semibold ${style.text}`}>
                  <span className={`inline-block w-2.5 h-2.5 rounded-full ${style.swatch}`} />
                  {style.label}
                  {isDraft && (
                    <span className="rounded bg-slate-500/80 text-white text-[10px] font-semibold px-1.5 py-0.5">
                      Concept
                    </span>
                  )}
                </span>
                <span className="text-sm font-semibold tabular-nums">{time}</span>
              </div>

              {conflict && conflict.level !== 'none' && (
                <div className={`mt-2 flex items-start gap-1.5 text-sm rounded-md p-2 ${conflict.level === 'hard' ? 'bg-red-50 text-red-700' : 'bg-amber-50 text-amber-700'}`}>
                  <AlertTriangle size={14} className="mt-0.5 shrink-0" />
                  <span>
                    {conflict.level === 'hard'
                      ? (conflict.hardWithConfirmed
                          ? 'Harde tijdoverlap met een al bevestigde dienst (koerier is al geïnformeerd):'
                          : 'Harde tijdoverlap met een ander concept:')
                      : 'Zelfde koerier, zelfde dag — samenloop:'}
                    <ul className="mt-0.5 list-disc list-inside">
                      {conflict.others.map((o) => <li key={o.id}>{describeOther(o)}</li>)}
                    </ul>
                  </span>
                </div>
              )}

              <div className="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-sm text-slate-600">
                <span className="inline-flex items-center gap-1">
                  {isOpen
                    ? <span className="text-amber-600 font-medium">● Open (nog niet toegewezen)</span>
                    : <><UserCircle2 size={14} /> {s.courierName ?? 'Koerier'}</>}
                </span>
                <span className="inline-flex items-center gap-1">
                  <TransportIcon size={14} /> {TRANSPORT_LABELS[s.transportMode]}
                </span>
              </div>

              <div className="mt-2 flex items-start gap-1 text-sm">
                <Users size={14} className="mt-0.5 text-slate-400 shrink-0" />
                <span className="text-slate-700">
                  {s.pharmacyIds.map((id) => pharmacyNames.get(id) ?? id).join(', ')}
                  {s.pharmacyIds.length > 1 && (
                    <span className="ml-1 text-xs text-slate-400">(gedeelde dienst)</span>
                  )}
                </span>
              </div>

              {s.shiftType === 'institution' && s.institutionIds.length > 0 && (
                <div className="mt-1 flex items-start gap-1 text-sm">
                  <MapPin size={14} className="mt-0.5 text-slate-400 shrink-0" />
                  <span className="text-slate-700">
                    {s.institutionIds.map((id) => institutionNames.get(id) ?? id).join(', ')}
                  </span>
                </div>
              )}

              {s.description && (
                <p className="mt-2 text-sm text-slate-500 italic">{s.description}</p>
              )}

              <div className="mt-3 flex justify-end gap-2 border-t border-slate-100 pt-2">
                {isDraft && (
                  <button
                    type="button" onClick={() => onConfirm(s)}
                    className="inline-flex items-center gap-1 text-sm font-medium text-green-700 hover:text-green-800 mr-auto"
                  >
                    <CheckCircle2 size={14} /> Bevestigen
                  </button>
                )}
                <button
                  type="button" onClick={() => onEdit(s)}
                  className="inline-flex items-center gap-1 text-sm text-slate-600 hover:text-slate-900"
                >
                  <Pencil size={14} /> Bewerken
                </button>
                <button
                  type="button" onClick={() => onDelete(s)}
                  className="inline-flex items-center gap-1 text-sm text-red-600 hover:text-red-700"
                >
                  <Trash2 size={14} /> Verwijderen
                </button>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
