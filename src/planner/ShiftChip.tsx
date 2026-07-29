import { AlertTriangle, Bike, Car, MessageSquare, Repeat, UserCircle2, Users } from 'lucide-react';
import { Shift, SmsLogEntry } from '../types';
import { ShiftConflict } from './conflicts';
import { TYPE_STYLES } from './constants';
import { SMS_ICON_CLASS, SMS_LABELS } from './sms';

// Eén dienst als gekleurde chip in een cel. Kleur = type. Open dienst (geen
// koerier) krijgt een gestreepte rand + "Open"-markering. Gedeelde dienst
// (meerdere apotheken) krijgt een Users-indicatie.
export default function ShiftChip(
  { shift, conflict, sms, onClick }: { shift: Shift; conflict?: ShiftConflict; sms?: SmsLogEntry; onClick?: () => void },
) {
  const style = TYPE_STYLES[shift.shiftType];
  const isOpen = !shift.courierId;
  const isShared = shift.pharmacyIds.length > 1;
  const isDraft = shift.status === 'draft';
  const isSchedule = !!shift.scheduleId;
  const conflictLevel = conflict?.level ?? 'none';
  const TransportIcon = shift.transportMode === 'car' ? Car : Bike;
  // Autodienst waarvan nog niet bekend is van wie de auto is. Sinds migratie 013
  // mag dat, maar het moet wél zichtbaar blijven — anders verdwijnt het stil.
  const carUnknown = shift.transportMode === 'car' && shift.carIsOwn === null;

  const time = shift.budgetedEndTime
    ? `${shift.startTime}–${shift.budgetedEndTime}`
    : shift.startTime;

  return (
    <button
      type="button"
      onClick={onClick}
      title={`${style.label}${isDraft ? ' · concept (nog niet bevestigd)' : ''}${isSchedule ? ' · uit rooster' : ''}${isShared ? ` · gedeeld (${shift.pharmacyIds.length} apotheken)` : ''}${isOpen ? ' · nog niet toegewezen' : ''}${carUnknown ? ' · auto onbekend' : ''}${sms ? ` · ${SMS_LABELS[sms.status]}` : ''}`}
      className={[
        'w-full text-left rounded-md px-2 py-1 text-xs leading-tight',
        style.bg, style.text,
        'border', style.border,
        (isOpen || isDraft) ? 'border-dashed border-2' : '',
        isDraft ? 'opacity-60' : '',
      ].join(' ')}
    >
      {isDraft && (
        <div className="mb-0.5">
          <span className="inline-block rounded bg-slate-500/80 text-white text-[10px] font-semibold px-1 leading-tight">
            Concept
          </span>
        </div>
      )}
      <div className="flex items-center justify-between gap-1">
        <span className="font-semibold tabular-nums">{time}</span>
        <span className="flex items-center gap-1 shrink-0">
          {conflictLevel === 'hard' && <AlertTriangle size={12} className="text-red-600" aria-label="Harde tijdoverlap" />}
          {conflictLevel === 'soft' && <AlertTriangle size={12} className="text-amber-500" aria-label="Samenloop zelfde dag" />}
          {sms && <MessageSquare size={12} className={SMS_ICON_CLASS[sms.status]} aria-label={SMS_LABELS[sms.status]} />}
          {isSchedule && <Repeat size={12} aria-label="Uit rooster" />}
          {isShared && <Users size={12} aria-label="Gedeelde dienst" />}
          <TransportIcon
            size={12}
            className={carUnknown ? 'text-amber-600' : ''}
            aria-label={carUnknown ? 'Auto, eigenaar nog onbekend' : shift.transportMode}
          />
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
