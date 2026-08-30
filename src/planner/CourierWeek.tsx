import { Bike, Car, Repeat, Users } from 'lucide-react';
import { Courier, Shift } from '../types';
import { formatDayHeader, toISODate } from './dates';
import { TYPE_STYLES, WEEKDAY_LABELS } from './constants';

interface Props {
  days: Date[];
  couriers: Courier[];
  shifts: Shift[];                      // al gefilterd door het weekoverzicht
  pharmacyNames: Map<string, string>;
  loading: boolean;
}

// Weekoverzicht met de KOERIER op de y-as. Alleen lezen: er zit geen enkele
// klikbare cel in, en dat is geen omissie maar het punt van dit scherm. Plannen
// gebeurt in het apotheekoverzicht, waar een cel één apotheek én één dag is —
// hier is een cel één koerier en één dag, en daar hoort geen "dienst toevoegen"
// bij zonder dat je zegt vóór welke apotheek.
//
// Rijen: elke koerier met minstens één dienst deze week, plus bovenaan een rij
// met de open diensten. Zonder die rij zou een niet-toegewezen dienst hier
// stilzwijgend verdwijnen, en dat is precies de dienst die aandacht nodig heeft.
export default function CourierWeek({ days, couriers, shifts, pharmacyNames, loading }: Props) {
  const byCourierDay = new Map<string, Map<string, Shift[]>>();
  for (const s of shifts) {
    const key = s.courierId ?? 'open';
    if (!byCourierDay.has(key)) byCourierDay.set(key, new Map());
    const byDay = byCourierDay.get(key)!;
    const list = byDay.get(s.shiftDate) ?? [];
    list.push(s);
    byDay.set(s.shiftDate, list);
  }

  const rows: { key: string; label: string; open: boolean }[] = [];
  if (byCourierDay.has('open')) {
    rows.push({ key: 'open', label: 'Open (niet toegewezen)', open: true });
  }
  for (const c of couriers) {
    if (byCourierDay.has(c.id)) rows.push({ key: c.id, label: c.name, open: false });
  }

  return (
    <div className="overflow-x-auto border border-slate-200 rounded-lg">
      <table className="w-full border-collapse text-sm">
        <thead>
          <tr className="bg-slate-50">
            <th className="sticky left-0 z-10 bg-slate-50 text-left font-semibold px-3 py-2 border-b border-slate-200 min-w-[160px]">
              Koerier
            </th>
            {days.map((d, i) => (
              <th key={i} className="px-2 py-2 border-b border-l border-slate-200 min-w-[130px]">
                <div className="font-semibold">{WEEKDAY_LABELS[i]}</div>
                <div className="text-xs font-normal text-slate-500">{formatDayHeader(d)}</div>
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr key={row.key} className="align-top">
              <td className={`sticky left-0 z-10 bg-white px-3 py-2 border-b border-slate-200 font-medium ${
                row.open ? 'text-slate-500 italic' : ''
              }`}>
                <span className="block truncate" title={row.label}>{row.label}</span>
              </td>
              {days.map((d, i) => {
                const dayISO = toISODate(d);
                const cell = byCourierDay.get(row.key)?.get(dayISO) ?? [];
                return (
                  <td key={i} className="px-1.5 py-1.5 border-b border-l border-slate-200">
                    {cell.length === 0 ? (
                      <div className="h-6" />
                    ) : (
                      <div className="space-y-1">
                        {cell
                          .slice()
                          .sort((a, b) => a.startTime.localeCompare(b.startTime))
                          .map((s) => (
                            <ReadOnlyChip key={s.id} shift={s} pharmacyNames={pharmacyNames} />
                          ))}
                      </div>
                    )}
                  </td>
                );
              })}
            </tr>
          ))}
          {rows.length === 0 && !loading && (
            <tr>
              <td colSpan={days.length + 1} className="px-3 py-6 text-center text-slate-400">
                Geen diensten in deze week — of alles valt buiten de filters.
              </td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
}

// Eén dienst, compact: begintijd, apotheek en vervoermiddel. Geen knop, want er
// valt hier niets te doen. De volledige apotheeknaam staat in de tooltip, samen
// met de rest van wat de chip niet kwijt kan.
function ReadOnlyChip(
  { shift, pharmacyNames }: { shift: Shift; pharmacyNames: Map<string, string> },
) {
  const style = TYPE_STYLES[shift.shiftType];
  const isDraft = shift.status === 'draft';
  const isShared = shift.pharmacyIds.length > 1;
  const TransportIcon = shift.transportMode === 'car' ? Car : Bike;
  // Autodienst waarvan nog niet bekend is van wie de auto is (migratie 013).
  // Zelfde amber markering als in ShiftChip, anders verdwijnt het hier stil.
  const carUnknown = shift.transportMode === 'car' && shift.carIsOwn === null;

  const names = shift.pharmacyIds.map((id) => pharmacyNames.get(id) ?? id);
  const full = names.join(', ') || 'geen apotheek';
  const time = shift.budgetedEndTime ? `${shift.startTime}–${shift.budgetedEndTime}` : shift.startTime;

  return (
    <div
      title={`${time} · ${full} · ${style.label}`
        + `${isDraft ? ' · concept (nog niet bevestigd)' : ''}`
        + `${shift.scheduleId ? ' · uit rooster' : ''}`
        + `${carUnknown ? ' · auto onbekend' : ''}`}
      className={[
        'rounded-md px-2 py-1 text-xs leading-tight border',
        style.bg, style.text, style.border,
        isDraft ? 'border-dashed border-2 opacity-60' : '',
      ].join(' ')}
    >
      <div className="flex items-center justify-between gap-1">
        <span className="font-semibold tabular-nums">{shift.startTime}</span>
        <span className="flex items-center gap-1 shrink-0">
          {shift.scheduleId && <Repeat size={12} aria-label="Uit rooster" />}
          {isShared && <Users size={12} aria-label="Gedeelde dienst" />}
          <TransportIcon
            size={12}
            className={carUnknown ? 'text-amber-600' : ''}
            aria-label={carUnknown ? 'Auto, eigenaar nog onbekend' : shift.transportMode}
          />
        </span>
      </div>
      {/* De naam wordt afgekapt met een ellips; de volledige naam zit in de
          tooltip hierboven. min-w-0 is nodig, anders weigert een flex-kind te
          krimpen en loopt de tekst de cel uit. */}
      <div className="mt-0.5 min-w-0 truncate">{full}</div>
    </div>
  );
}
