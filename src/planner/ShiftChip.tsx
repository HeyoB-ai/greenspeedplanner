import { Bike, Car, UserCircle2, Users } from 'lucide-react';
import { Shift } from '../types';
import { TYPE_STYLES } from './constants';

// Eén dienst als gekleurde chip in een cel. Kleur = type. Open dienst (geen
// koerier) krijgt een gestreepte rand + "Open"-markering. Gedeelde dienst
// (meerdere apotheken) krijgt een Users-indicatie.
export default function ShiftChip({ shift, onClick }: { shift: Shift; onClick?: () => void }) {
  const style = TYPE_STYLES[shift.shiftType];
  const isOpen = !shift.courierId;
  const isShared = shift.pharmacyIds.length > 1;
  const TransportIcon = shift.transportMode === 'car' ? Car : Bike;

  const time = shift.budgetedEndTime
    ? `${shift.startTime}–${shift.budgetedEndTime}`
    : shift.startTime;

  return (
    <button
      type="button"
      onClick={onClick}
      title={`${style.label}${isShared ? ` · gedeeld (${shift.pharmacyIds.length} apotheken)` : ''}${isOpen ? ' · nog niet toegewezen' : ''}`}
      className={[
        'w-full text-left rounded-md px-2 py-1 text-xs leading-tight',
        style.bg, style.text,
        'border', style.border,
        isOpen ? 'border-dashed border-2' : '',
      ].join(' ')}
    >
      <div className="flex items-center justify-between gap-1">
        <span className="font-semibold tabular-nums">{time}</span>
        <span className="flex items-center gap-1 shrink-0">
          {isShared && <Users size={12} aria-label="Gedeelde dienst" />}
          <TransportIcon size={12} aria-label={shift.transportMode} />
        </span>
      </div>
      <div className="flex items-center gap-1 mt-0.5">
        {isOpen ? (
          <span className="inline-flex items-center gap-1 font-medium">
            <span className="inline-block w-1.5 h-1.5 rounded-full bg-current opacity-70" />
            Open
          </span>
        ) : (
          <span className="inline-flex items-center gap-1 truncate">
            <UserCircle2 size={12} className="shrink-0" />
            <span className="truncate">{shift.courierName ?? 'Koerier'}</span>
          </span>
        )}
      </div>
    </button>
  );
}
