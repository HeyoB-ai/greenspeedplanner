import { Fragment, useEffect, useMemo, useState } from 'react';
import { ClipboardList, Download, X } from 'lucide-react';
import { BenuOverviewRow } from '../types';
import { BENU_STATUS_LABELS, BENU_STATUS_STYLES, getBenuOverview } from './benuOverviewService';
import {
  downloadBenuHqExcel, downloadExtraExcel, getExtraWeek, getPdaWeek, getRosterWeek, weekOf,
} from './benuExportService';

interface Props {
  onClose: () => void;
}

function isoDaysAgo(n: number): string {
  const d = new Date();
  d.setDate(d.getDate() - n);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

const dateFmt = new Intl.DateTimeFormat('nl-NL', { weekday: 'short', day: 'numeric', month: 'short' });
const stampFmt = new Intl.DateTimeFormat('nl-NL', {
  day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit',
});

// 'YYYY-MM-DD' als lokale datum; new Date(iso) zou om middernacht UTC vallen
// en in de avond een dag kunnen verspringen.
function shiftDateText(iso: string): string {
  const [y, m, d] = iso.split('-').map(Number);
  return dateFmt.format(new Date(y, m - 1, d));
}

// BENU-invoer: wat koeriers per dienst opgaven en hoe de apotheek reageerde
// (fase 4, migratie 047). Puur inzicht — de afhandeling loopt via de mails.
export default function BenuOverview({ onClose }: Props) {
  const [rows, setRows] = useState<BenuOverviewRow[]>([]);
  const [from, setFrom] = useState(isoDaysAgo(30));
  const [to, setTo] = useState(isoDaysAgo(0));
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [onlyExtra, setOnlyExtra] = useState(false);
  const [onlyOpen, setOnlyOpen] = useState(false);

  const [exportDate, setExportDate] = useState(isoDaysAgo(0));
  const [exportBusy, setExportBusy] = useState<'hq' | 'extra' | null>(null);
  const [exportError, setExportError] = useState('');
  const wk = useMemo(() => weekOf(exportDate), [exportDate]);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    getBenuOverview(from, to)
      .then((list) => { if (!cancelled) { setRows(list); setError(''); } })
      .catch((e: any) => { if (!cancelled) setError(e?.message ?? 'Laden mislukt.'); })
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [from, to]);

  const shown = useMemo(() => rows.filter((r) =>
    (!onlyOpen || r.status === 'pending' || r.status === 'submitted')
    && (!onlyExtra || (r.extra_minutes !== null && r.extra_minutes > 0)),
  ), [rows, onlyOpen, onlyExtra]);

  const totalExtra = useMemo(
    () => shown.reduce((sum, r) => sum + (r.extra_minutes ?? 0), 0), [shown]);

  async function downloadHq() {
    setExportBusy('hq');
    setExportError('');
    try {
      const [roster, pda] = await Promise.all([getRosterWeek(wk.from, wk.to), getPdaWeek(wk.from, wk.to)]);
      downloadBenuHqExcel(roster, pda, wk.isoWeek, wk.year);
    } catch (e: any) {
      setExportError(e?.message ?? 'Exporteren mislukt.');
    } finally {
      setExportBusy(null);
    }
  }

  async function downloadExtra() {
    setExportBusy('extra');
    setExportError('');
    try {
      downloadExtraExcel(await getExtraWeek(wk.from, wk.to), wk.isoWeek, wk.year);
    } catch (e: any) {
      setExportError(e?.message ?? 'Exporteren mislukt.');
    } finally {
      setExportBusy(null);
    }
  }

  return (
    <div className="fixed inset-0 z-50 bg-black/40 flex items-start justify-center p-4 overflow-y-auto" onClick={onClose}>
      <div
        className="bg-white rounded-xl shadow-lg w-full max-w-[95vw] xl:max-w-[80rem] my-8"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between px-5 py-3 border-b border-slate-200">
          <h2 className="font-semibold text-slate-800 inline-flex items-center gap-2">
            <ClipboardList size={16} className="text-green-700" /> BENU-invoer
          </h2>
          <button onClick={onClose} className="text-slate-400 hover:text-slate-700"><X size={18} /></button>
        </div>

        <div className="p-5 space-y-4">
          <div className="flex flex-wrap items-center gap-3 text-sm">
            <label className="inline-flex items-center gap-1.5">
              <span className="text-slate-500">Van</span>
              <input type="date" value={from} onChange={(e) => setFrom(e.target.value)}
                className="border border-slate-300 rounded-lg px-2 py-1 bg-white" />
            </label>
            <label className="inline-flex items-center gap-1.5">
              <span className="text-slate-500">t/m</span>
              <input type="date" value={to} onChange={(e) => setTo(e.target.value)}
                className="border border-slate-300 rounded-lg px-2 py-1 bg-white" />
            </label>
            <label className="inline-flex items-center gap-1.5 text-slate-600 cursor-pointer">
              <input type="checkbox" checked={onlyExtra} onChange={(e) => setOnlyExtra(e.target.checked)} />
              Alleen met extra minuten
            </label>
            <label className="inline-flex items-center gap-1.5 text-slate-600 cursor-pointer">
              <input type="checkbox" checked={onlyOpen} onChange={(e) => setOnlyOpen(e.target.checked)} />
              Alleen openstaand (pending + submitted)
            </label>
            <span className="ml-auto text-slate-500 tabular-nums">
              {shown.length} regels · {totalExtra} extra min
            </span>
          </div>

          {error && <p className="text-sm text-red-600">{error}</p>}
          {loading && <p className="text-sm text-slate-500">Laden…</p>}

          {!loading && !error && shown.length === 0 && (
            <p className="text-sm text-slate-500">Geen regels in deze periode.</p>
          )}

          {!loading && shown.length > 0 && (
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-slate-200 text-left text-xs text-slate-500">
                    <th className="py-2 pr-3 font-medium">Datum</th>
                    <th className="py-2 pr-3 font-medium">Koerier</th>
                    <th className="py-2 pr-3 font-medium">Apotheek</th>
                    <th className="py-2 pr-3 font-medium text-right">Gepland</th>
                    <th className="py-2 pr-3 font-medium text-right">PDA</th>
                    <th className="py-2 pr-3 font-medium text-right">Extra</th>
                    <th className="py-2 pr-3 font-medium">Status</th>
                    <th className="py-2 font-medium">Ingediend</th>
                  </tr>
                </thead>
                <tbody>
                  {shown.map((r) => (
                    <Fragment key={`${r.shift_entry_id}-${r.pharmacy_id}`}>
                      <tr className="border-b border-slate-100">
                        <td className="py-2 pr-3 whitespace-nowrap tabular-nums">{shiftDateText(r.shift_date)}</td>
                        <td className="py-2 pr-3">{r.courier_name}</td>
                        <td className="py-2 pr-3">{r.pharmacy_name}</td>
                        <td className="py-2 pr-3 text-right tabular-nums">{r.planned_minutes ?? '—'}</td>
                        <td className="py-2 pr-3 text-right tabular-nums">{r.pda_minutes ?? '—'}</td>
                        <td className="py-2 pr-3 text-right tabular-nums">
                          {r.extra_minutes !== null && r.extra_minutes > 0
                            ? <span className="font-semibold text-amber-700">+{r.extra_minutes}</span>
                            : '—'}
                        </td>
                        <td className="py-2 pr-3">
                          <span className={`rounded px-1.5 py-0.5 text-[11px] font-semibold whitespace-nowrap ${BENU_STATUS_STYLES[r.status]}`}>
                            {BENU_STATUS_LABELS[r.status]}
                          </span>
                        </td>
                        <td className="py-2 whitespace-nowrap tabular-nums text-slate-500">
                          {r.submitted_at ? stampFmt.format(new Date(r.submitted_at)) : '—'}
                        </td>
                      </tr>
                      {r.status === 'disputed' && r.pharmacy_note && (
                        <tr className="bg-red-50 border-b border-slate-100">
                          <td colSpan={8} className="px-3 py-1.5 text-xs text-slate-500">
                            Apotheek: {r.pharmacy_note}
                          </td>
                        </tr>
                      )}
                    </Fragment>
                  ))}
                </tbody>
              </table>
            </div>
          )}

          <hr className="border-slate-200" />

          <div className="pt-4 space-y-3">
            <h3 className="text-sm font-semibold text-slate-700">Week exporteren</h3>
            <div className="flex flex-wrap items-center gap-3 text-sm">
              <label>
                <span className="text-slate-500 mr-1.5">Week van</span>
                <input type="date" value={exportDate} onChange={(e) => setExportDate(e.target.value)}
                  className="border border-slate-300 rounded-lg px-2 py-1 bg-white" />
              </label>
              <span className="text-slate-500">
                Week {wk.isoWeek} · {wk.from} t/m {wk.to} · {wk.parity === 'even' ? 'even' : 'oneven'}
              </span>
            </div>
            <div className="flex flex-wrap gap-2">
              <button onClick={downloadHq} disabled={!!exportBusy}
                className="inline-flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-sm bg-green-700 text-white hover:bg-green-800 disabled:opacity-50">
                <Download size={14} />
                {exportBusy === 'hq' ? 'Bezig…' : 'Roostertijden + PDA (BENU HQ)'}
              </button>
              <button onClick={downloadExtra} disabled={!!exportBusy}
                className="inline-flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-sm bg-slate-700 text-white hover:bg-slate-800 disabled:opacity-50">
                <Download size={14} />
                {exportBusy === 'extra' ? 'Bezig…' : 'Extra tijd per apotheek'}
              </button>
            </div>
            {exportError && <p className="text-sm text-red-600">{exportError}</p>}
          </div>
        </div>
      </div>
    </div>
  );
}
