import { ArrowLeft, Bike, Car, MapPin, UserCircle2, Users } from 'lucide-react';
import { Shift } from '../types';
import { TRANSPORT_LABELS, TYPE_STYLES, WEEKDAY_LABELS_LONG } from './constants';

interface Props {
  date: Date;
  shifts: Shift[];
  pharmacyNames: Map<string, string>;
  institutionNames: Map<string, string>;
  onBack: () => void;
}

// Ingezoomde dagweergave met meer detail per dienst.
export default function DayView({ date, shifts, pharmacyNames, institutionNames, onBack }: Props) {
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
          return (
            <div key={s.id} className={`rounded-lg border ${style.border} bg-white p-3`}>
              <div className="flex items-center justify-between">
                <span className={`inline-flex items-center gap-2 text-sm font-semibold ${style.text}`}>
                  <span className={`inline-block w-2.5 h-2.5 rounded-full ${style.swatch}`} />
                  {style.label}
                </span>
                <span className="text-sm font-semibold tabular-nums">{time}</span>
              </div>

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
            </div>
          );
        })}
      </div>
    </div>
  );
}
