import { useEffect, useMemo, useState } from 'react';
import { AlertTriangle, Clock, Info, Send, Undo2, X } from 'lucide-react';
import { ExtraWorkRow } from '../types';
import {
  EXTRA_WORK_LABELS, EXTRA_WORK_STYLES, getExtraWork, hoursLeft, minutesText,
  releaseExtraWork, reopenExtraWork,
} from './extraWorkService';

interface Props {
  onClose: () => void;
}

function isoDaysAgo(n: number): string {
  const d = new Date();
  d.setDate(d.getDate() - n);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

// Meerwerk: de planner kijkt ertussen (fase 9, migratie 031).
//
// Het scherm bestaat omdat de toelichting van de koerier naar de klant gaat.
// "Duurde langer omdat het druk was op de weg" is prima; "moest wachten want de
// assistente was er niet" is dat niet. Daarom staat de tekst hier bewerkbaar en
// vertrekt er niets voordat iemand op vrijgeven heeft geklikt.
export default function ExtraWork({ onClose }: Props) {
  const [rows, setRows] = useState<ExtraWorkRow[]>([]);
  const [from, setFrom] = useState(isoDaysAgo(60));
  const [to, setTo] = useState(isoDaysAgo(0));
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [busyId, setBusyId] = useState<string | null>(null);
  const [onlyOpen, setOnlyOpen] = useState(true);

  // De tekst die naar de klant gaat, per melding. Voorgevuld met wat de koerier
  // schreef: de planner herschrijft of laat staan, maar ziet altijd wat er gaat.
  const [notes, setNotes] = useState<Record<string, string>>({});

  async function reload() {
    setLoading(true);
    try {
      const list = await getExtraWork(from, to);
      setRows(list);
      setNotes(Object.fromEntries(list.map((r) => [
        r.extra_work_id, r.planner_note ?? r.courier_note ?? '',
      ])));
      setError('');
    } catch (e: any) {
      setError(e?.message ?? 'Laden mislukt.');
    } finally {
      setLoading(false);
    }
  }
  useEffect(() => { reload(); }, [from, to]);

  const shown = useMemo(
    () => (onlyOpen ? rows.filter((r) => r.status === 'new' || r.status === 'released') : rows),
    [rows, onlyOpen]);

  const waiting = useMemo(() => rows.filter((r) => r.status === 'new').length, [rows]);
  const noEmail = useMemo(
    () => rows.filter((r) => r.status === 'new' && !r.billing_email), [rows]);

  async function release(r: ExtraWorkRow) {
    setBusyId(r.extra_work_id);
    setError('');
    try {
      await releaseExtraWork(r.extra_work_id, notes[r.extra_work_id]?.trim() || null);
      await reload();
    } catch (e: any) {
      setError(e?.message ?? 'Vrijgeven mislukt.');
    } finally {
      setBusyId(null);
    }
  }

  async function reopen(r: ExtraWorkRow) {
    setBusyId(r.extra_work_id);
    setError('');
    try {
      await reopenExtraWork(r.extra_work_id);
      await reload();
    } catch (e: any) {
      setError(e?.message ?? 'Terugzetten mislukt.');
    } finally {
      setBusyId(null);
    }
  }

  return (
    <div className="fixed inset-0 z-50 bg-black/40 flex items-start justify-center p-4 overflow-y-auto" onClick={onClose}>
      <div
        className="bg-white rounded-xl shadow-lg w-full max-w-[95vw] xl:max-w-[72rem] my-8"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between px-5 py-3 border-b border-slate-200">
          <h2 className="font-semibold text-slate-800 inline-flex items-center gap-2">
            <Clock size={16} className="text-green-700" /> Meerwerk
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
              <input type="checkbox" checked={onlyOpen} onChange={(e) => setOnlyOpen(e.target.checked)} />
              Alleen openstaande
            </label>
            <span className="ml-auto text-slate-500">
              {waiting > 0 ? `${waiting} wacht op vrijgave` : 'niets wacht op vrijgave'}
            </span>
          </div>

          {error && <p className="text-sm text-red-600">{error}</p>}
          {loading && <p className="text-sm text-slate-500">Laden…</p>}

          {!loading && noEmail.length > 0 && (
            <div className="flex items-start gap-2 rounded-lg bg-amber-50 border border-amber-200 text-amber-800 text-sm p-3">
              <AlertTriangle size={15} className="mt-0.5 shrink-0" />
              <span>
                {noEmail.length === 1 ? 'Eén melding kan' : `${noEmail.length} meldingen kunnen`} niet
                vrijgegeven worden: de apotheek heeft geen e-mailadres
                ({[...new Set(noEmail.map((r) => r.pharmacy_name))].join(', ')}). Vul dat in bij
                <strong> Apotheken</strong>.
              </span>
            </div>
          )}

          {!loading && shown.length === 0 && (
            <p className="text-sm text-slate-500">
              Geen meerwerk in deze periode{onlyOpen && rows.length > 0 && ' dat nog openstaat'}.
            </p>
          )}

          <ul className="space-y-3">
            {shown.map((r) => {
              const busy = busyId === r.extra_work_id;
              const left = hoursLeft(r.respond_by);
              return (
                <li key={r.extra_work_id} className="rounded-lg border border-slate-200 p-3">
                  <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
                    <span className="font-medium text-slate-800">{r.pharmacy_name}</span>
                    <span className="text-sm text-slate-500 tabular-nums">{r.shift_date}</span>
                    <span className="text-sm text-slate-500">{r.courier_name ?? 'open dienst'}</span>
                    <span className={`rounded px-1.5 py-0.5 text-[11px] font-semibold ${EXTRA_WORK_STYLES[r.status]}`}>
                      {EXTRA_WORK_LABELS[r.status]}
                    </span>
                    <span className="ml-auto text-sm tabular-nums">
                      <span className="text-slate-500">
                        {minutesText(r.planned_minutes)} gepland, {minutesText(r.actual_minutes)} werkelijk ·{' '}
                      </span>
                      <strong className="text-amber-700">{minutesText(r.share_minutes)} extra</strong>
                      {r.share_pct < 100 && (
                        <span className="text-slate-400"> ({Number(r.share_pct).toFixed(0)}% van deze dienst)</span>
                      )}
                    </span>
                  </div>

                  {r.courier_note && (
                    <p className="mt-2 text-xs text-slate-500">
                      Koerier schreef: <span className="italic">“{r.courier_note}”</span>
                    </p>
                  )}

                  {r.status === 'new' && (
                    <div className="mt-2 space-y-2">
                      <label className="block">
                        <span className="block text-xs text-slate-500 mb-1">
                          Wat de apotheek te lezen krijgt
                        </span>
                        <textarea
                          rows={2} value={notes[r.extra_work_id] ?? ''} disabled={busy}
                          onChange={(e) => setNotes((m) => ({ ...m, [r.extra_work_id]: e.target.value }))}
                          className="w-full border border-slate-300 rounded-lg px-2 py-1.5 text-sm bg-white disabled:opacity-60"
                        />
                      </label>
                      <div className="flex items-center gap-2">
                        <button
                          onClick={() => release(r)} disabled={busy || !r.billing_email}
                          className="inline-flex items-center gap-1.5 px-3 py-1.5 text-sm bg-green-600 hover:bg-green-700 disabled:opacity-40 text-white rounded-lg font-medium"
                          title={r.billing_email
                            ? `Versturen naar ${r.billing_email}`
                            : 'Deze apotheek heeft geen e-mailadres'}
                        >
                          <Send size={15} /> {busy ? 'Bezig…' : 'Vrijgeven'}
                        </button>
                        <span className="text-xs text-slate-400">
                          {r.billing_email ?? 'geen adres bekend'}
                        </span>
                      </div>
                    </div>
                  )}

                  {r.status !== 'new' && (
                    <div className="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-slate-500">
                      {r.planner_note && <span className="italic">“{r.planner_note}”</span>}
                      {r.status === 'released' && (
                        <span>
                          {left != null
                            ? `nog ${left} uur om te reageren`
                            : 'de termijn is verstreken; verloopt bij de volgende verzendronde'}
                        </span>
                      )}
                      {r.responded_at && (
                        <span>
                          gereageerd op {r.responded_at.slice(0, 10)}
                          {r.response_note && <> — “{r.response_note}”</>}
                        </span>
                      )}
                      <button
                        onClick={() => reopen(r)} disabled={busy}
                        className="ml-auto inline-flex items-center gap-1 text-slate-500 hover:text-slate-800 disabled:opacity-60"
                        title="Terugzetten naar 'wacht op vrijgave'. De verstuurde link doet daarna niets meer."
                      >
                        <Undo2 size={13} /> Terugzetten
                      </button>
                    </div>
                  )}
                </li>
              );
            })}
          </ul>

          <details className="group">
            <summary className="inline-flex cursor-pointer list-none items-center gap-1.5 text-xs text-slate-400 hover:text-slate-600 [&::-webkit-details-marker]:hidden">
              <Info size={13} />
              Hoe werkt dit?
            </summary>
            <div className="mt-2 space-y-2 border-l-2 border-slate-100 pl-3 text-xs text-slate-500">
              <p>
                Een melding ontstaat automatisch zodra een dienst meer dan de ingestelde drempel
                uitloopt, maar er gaat <strong>niets de deur uit voordat jij vrijgeeft</strong>. De
                tekst die je hierboven laat staan is precies wat de apotheek leest.
              </p>
              <p>
                Na vrijgave heeft de apotheek 48 uur. <strong>Goedgekeurd</strong> en{' '}
                <strong>geen reactie</strong> worden allebei gefactureerd, maar blijven apart
                herkenbaar — bij het tweede heeft nooit iemand gekeken. <strong>Betwist</strong>{' '}
                betekent dat alleen de geplande uren op de factuur komen tot er telefonisch iets is
                afgesproken.
              </p>
              <p>
                De koerier wordt in alle gevallen gewoon uitbetaald. Een geschil met de klant staat
                daar los van.
              </p>
            </div>
          </details>
        </div>
      </div>
    </div>
  );
}
