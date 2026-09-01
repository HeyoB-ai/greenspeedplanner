import { useEffect, useMemo, useState } from 'react';
import { AlertTriangle, Check, FileText, Info, RefreshCw, Undo2, X } from 'lucide-react';
import { DeclarationRow } from '../types';
import {
  RULE_LABELS, STATUS_LABELS, doubleChargedKm, euroText, getDeclarations, hoursText,
  kmText, minutesText, recomputeOpenDeclarations, reviewDeclaration,
} from './declarationService';

interface Props {
  onClose: () => void;
}

// 'YYYY-MM-DD' van vandaag min n dagen, zonder tijdzone-omweg.
function isoDaysAgo(n: number): string {
  const d = new Date();
  d.setDate(d.getDate() - n);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

const STATUS_STYLES: Record<string, string> = {
  open:      'bg-slate-100 text-slate-600',
  submitted: 'bg-blue-100 text-blue-800',
  approved:  'bg-green-100 text-green-800',
  disputed:  'bg-red-100 text-red-800',
};

// Overzicht van de nadeclaraties (migraties 018/019). Per dienst staat er wat de
// koerier opgaf naast wat het systeem berekende, met het verschil erbij — dat
// verschil is het hele punt van dit scherm.
//
// Er staat geen tarief of drempel in deze code: declaration_overview() levert
// kilometers, tarief én bedrag al uitgerekend aan, zodat een tariefwijziging in
// de database vanzelf doorwerkt.
export default function Declarations({ onClose }: Props) {
  const [rows, setRows] = useState<DeclarationRow[]>([]);
  const [from, setFrom] = useState(isoDaysAgo(30));
  const [to, setTo] = useState(isoDaysAgo(0));
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [busyId, setBusyId] = useState<string | null>(null);
  const [disputing, setDisputing] = useState<string | null>(null);
  const [disputeNote, setDisputeNote] = useState('');
  const [onlyOpen, setOnlyOpen] = useState(false);

  async function reload() {
    setLoading(true);
    try {
      setRows(await getDeclarations(from, to));
      setError('');
    } catch (e: any) {
      setError(e?.message ?? 'Laden mislukt.');
    } finally {
      setLoading(false);
    }
  }
  useEffect(() => { reload(); }, [from, to]);

  const shown = useMemo(
    () => (onlyOpen ? rows.filter((r) => r.status === 'open' || r.status === 'submitted') : rows),
    [rows, onlyOpen],
  );

  const incomplete = useMemo(() => rows.filter((r) => r.computed_incomplete).length, [rows]);

  async function review(id: string, action: 'approve' | 'dispute' | 'reopen', note: string | null) {
    setBusyId(id);
    setError('');
    try {
      await reviewDeclaration(id, action, note);
      setDisputing(null);
      setDisputeNote('');
      await reload();
    } catch (e: any) {
      setError(e?.message ?? 'Opslaan mislukt.');
    } finally {
      setBusyId(null);
    }
  }

  async function recompute() {
    setBusyId('all');
    setError('');
    try {
      const n = await recomputeOpenDeclarations();
      await reload();
      if (n === 0) setError('Er was niets om te hertellen.');
    } catch (e: any) {
      setError(e?.message ?? 'Hertellen mislukt.');
    } finally {
      setBusyId(null);
    }
  }

  return (
    <div className="fixed inset-0 z-50 bg-black/40 flex items-start justify-center p-4 overflow-y-auto" onClick={onClose}>
      {/* Breed genoeg voor acht kolommen met namen erin. max-w-[95vw] houdt hem
          op een smal scherm binnen beeld; de tabel zelf krijgt hieronder een
          min-breedte, zodat kolommen bij ruimtegebrek een schuifbalk opleveren
          in plaats van afgekapte tekst. */}
      <div
        className="bg-white rounded-xl shadow-lg w-full max-w-[95vw] xl:max-w-[88rem] my-8"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between px-5 py-3 border-b border-slate-200">
          <h2 className="font-semibold text-slate-800 inline-flex items-center gap-2">
            <FileText size={16} className="text-green-700" /> Nadeclaraties
          </h2>
          <button onClick={onClose} className="text-slate-400 hover:text-slate-700"><X size={18} /></button>
        </div>

        <div className="p-5 space-y-4">
          <div className="flex flex-wrap items-center gap-3 text-sm">
            <label className="inline-flex items-center gap-1.5">
              <span className="text-slate-500">Van</span>
              <input
                type="date" value={from} onChange={(e) => setFrom(e.target.value)}
                className="border border-slate-300 rounded-lg px-2 py-1 bg-white"
              />
            </label>
            <label className="inline-flex items-center gap-1.5">
              <span className="text-slate-500">t/m</span>
              <input
                type="date" value={to} onChange={(e) => setTo(e.target.value)}
                className="border border-slate-300 rounded-lg px-2 py-1 bg-white"
              />
            </label>
            <label className="inline-flex items-center gap-1.5 text-slate-600">
              <input type="checkbox" checked={onlyOpen} onChange={(e) => setOnlyOpen(e.target.checked)} />
              Alleen openstaande
            </label>
            <button
              onClick={recompute} disabled={busyId === 'all'}
              className="ml-auto inline-flex items-center gap-1 text-slate-600 hover:text-slate-900 disabled:opacity-60"
              title="Opnieuw doorrekenen na een gecorrigeerde afstand, standplaats of tarief. Goedgekeurde declaraties blijven staan."
            >
              <RefreshCw size={15} /> Hertellen
            </button>
          </div>

          {error && <p className="text-sm text-red-600">{error}</p>}
          {loading && <p className="text-sm text-slate-500">Laden…</p>}

          {!loading && incomplete > 0 && (
            <div className="flex items-start gap-2 rounded-lg bg-amber-50 border border-amber-200 text-amber-800 text-sm p-3">
              <AlertTriangle size={15} className="mt-0.5 shrink-0" />
              <span>
                {incomplete === 1 ? 'Eén declaratie is' : `${incomplete} declaraties zijn`} onvolledig berekend —
                er ontbreekt een standplaats, een afstand of een tarief. De reden staat in de regel zelf.
                Vul het aan en druk daarna op Hertellen.
              </span>
            </div>
          )}

          {!loading && shown.length === 0 && (
            <p className="text-sm text-slate-500">Geen declaraties in deze periode.</p>
          )}

          {shown.length > 0 && (
            <div className="overflow-x-auto">
              {/* min-w dwingt af dat de kolommen hun natuurlijke breedte houden.
                  Past dat niet, dan schuift deze tabel horizontaal — dat is de
                  bedoeling; namen half tonen is dat niet. */}
              <table className="w-full min-w-[68rem] text-sm">
                <thead>
                  <tr className="text-left text-xs uppercase tracking-wide text-slate-500 border-b border-slate-200">
                    <th className="py-2 pr-3 font-medium">Dienst</th>
                    <th className="py-2 px-3 font-medium">Koerier</th>
                    <th className="py-2 px-3 font-medium">Gepland</th>
                    <th className="py-2 px-3 font-medium">Opgegeven</th>
                    <th className="py-2 px-3 font-medium">Verschil</th>
                    <th className="py-2 px-3 font-medium">Reiskosten</th>
                    <th className="py-2 px-3 font-medium">Status</th>
                    <th className="py-2 pl-3 font-medium"></th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {shown.map((r) => {
                    const diff = r.planned_minutes != null && r.actual_minutes != null
                      ? r.actual_minutes - r.planned_minutes
                      : null;
                    const busy = busyId === r.declaration_id;
                    // Kilometers als onkostenpost naast een berekende
                    // vergoeding: dezelfde rit twee keer op de factuur. Dat
                    // wil je zien vóór het factureren, niet erna.
                    const doubleKm = doubleChargedKm(r);

                    return (
                      <tr key={r.declaration_id} className={r.computed_incomplete ? 'bg-amber-50/60' : undefined}>
                        <td className="py-2 pr-3 align-top">
                          <div className="tabular-nums whitespace-nowrap">{r.shift_date}</div>
                          <div className="text-xs text-slate-500">{(r.pharmacies ?? []).join(', ')}</div>
                        </td>
                        <td className="py-2 px-3 align-top">
                          <span className="whitespace-nowrap">{r.courier_name}</span>
                          <div className="text-xs text-slate-500">
                            {r.transport_mode === 'car' ? (r.own_car ? 'eigen auto' : 'auto') : 'fiets'}
                          </div>
                        </td>
                        {/* Zonder budgeted_end_time valt er niets te vergelijken.
                            Dat met zoveel woorden zeggen, want een kaal streepje
                            onder een starttijd leest als een storing. */}
                        <td className="py-2 px-3 align-top tabular-nums whitespace-nowrap">
                          {r.planned_end ? (
                            <>
                              {r.planned_start}–{r.planned_end}
                              <div className="text-xs text-slate-500">{minutesText(r.planned_minutes)}</div>
                            </>
                          ) : (
                            <>
                              {r.planned_start ? `vanaf ${r.planned_start}` : '—'}
                              <div className="text-xs text-slate-400">geen eindtijd gepland</div>
                            </>
                          )}
                        </td>
                        <td className="py-2 px-3 align-top tabular-nums whitespace-nowrap">
                          {r.actual_start && r.actual_end ? `${r.actual_start}–${r.actual_end}` : '—'}
                          <div className="text-xs text-slate-500">{minutesText(r.actual_minutes)}</div>
                        </td>
                        <td className="py-2 px-3 align-top tabular-nums whitespace-nowrap">
                          {diff != null ? (
                            <span className={Math.abs(diff) >= 30 ? 'font-medium text-amber-700' : 'text-slate-600'}>
                              {diff > 0 ? '+' : ''}{minutesText(diff)}
                            </span>
                          ) : r.planned_minutes == null ? (
                            // Er is geen geplande duur; leeg laten zou lezen als
                            // "geen verschil".
                            <span className="text-xs text-slate-400">niets te vergelijken</span>
                          ) : (
                            <span className="text-slate-400">—</span>
                          )}
                        </td>
                        <td className="py-2 px-3 align-top">
                          {r.claims_travel === null && <span className="text-slate-400">—</span>}
                          {r.claims_travel === false && <span className="text-slate-500">geen claim</span>}
                          {r.claims_travel === true && (
                            <>
                              <div className="tabular-nums">
                                {euroText(r.amount_eur)}
                                <span className="text-slate-500"> · {kmText(r.computed_reimbursable_km)}</span>
                              </div>
                              <div className="text-xs text-slate-500">
                                {r.computed_rule ? RULE_LABELS[r.computed_rule] : 'geen regel'}
                                {r.own_car && r.own_car_km != null && (
                                  <> · opgegeven {kmText(r.own_car_km)}, berekend {kmText(r.computed_distance_km)}</>
                                )}
                                {!r.own_car && r.computed_pharmacy_name && <> · via {r.computed_pharmacy_name}</>}
                              </div>
                            </>
                          )}
                          {r.computed_incomplete && (
                            <div className="text-xs text-amber-700 mt-0.5">{r.computed_reason}</div>
                          )}
                          {/* Onkosten staan bewust in deze kolom en niet in een
                              eigen: het zijn er meestal nul, en een lege kolom
                              over de hele breedte kost meer dan hij oplevert. */}
                          {r.expenses_amount > 0 && (
                            <div className="text-xs text-slate-600 mt-0.5">
                              Onkosten {euroText(r.expenses_amount)}
                              <span className="text-slate-400">
                                {' · '}{r.expenses.map((e) => e.description).join(', ')}
                              </span>
                              {r.expects_receipt && (
                                <span className="ml-1.5 rounded bg-amber-100 text-amber-800 text-[10px] font-semibold px-1.5 py-0.5">
                                  bon verwacht
                                </span>
                              )}
                            </div>
                          )}
                          {doubleKm.length > 0 && (
                            <div className="mt-1 flex items-start gap-1 text-xs text-rose-700">
                              <AlertTriangle size={12} className="mt-0.5 shrink-0" />
                              <span>
                                Kilometers staan óók als onkost ({doubleKm.join(', ')}) naast een
                                berekende reiskostenvergoeding — mogelijk dubbel doorbelast.
                              </span>
                            </div>
                          )}
                          {r.courier_note && (
                            <div className="text-xs text-slate-500 mt-0.5 italic">“{r.courier_note}”</div>
                          )}
                        </td>
                        <td className="py-2 px-3 align-top">
                          <span className={`rounded px-1.5 py-0.5 text-[11px] font-semibold ${STATUS_STYLES[r.status]}`}>
                            {STATUS_LABELS[r.status]}
                          </span>
                          {/* Tijdigheid: ingediend → hoe lang na afloop; nog niet
                              ingediend → hoe lang de rij al openstaat. Amber is
                              een signaal, geen afkeuring: de link blijft werken
                              en te laat ingevuld is nog altijd ingevuld. */}
                          {r.submitted_in_time !== null && (
                            <div
                              className={`text-xs mt-0.5 ${r.submitted_in_time ? 'text-slate-500' : 'text-amber-700'}`}
                              title={`Ingediend ${hoursText(r.hours_after_end)} na afloop van de dienst. Verwacht binnen ${r.expected_within_hours} uur.`}
                            >
                              na {hoursText(r.hours_after_end)}
                              {!r.submitted_in_time && ` · buiten ${r.expected_within_hours} u`}
                            </div>
                          )}
                          {r.status === 'open' && r.hours_after_end != null && (
                            <div className={`text-xs mt-0.5 ${
                              r.hours_after_end > r.expected_within_hours ? 'text-amber-700' : 'text-slate-500'
                            }`}>
                              open sinds {hoursText(r.hours_after_end)}
                            </div>
                          )}
                          {r.reviewed_at && r.reviewer_name && (
                            <div className="text-xs text-slate-500 mt-0.5">door {r.reviewer_name}</div>
                          )}
                          {r.review_note && (
                            <div className="text-xs text-red-700 mt-0.5">{r.review_note}</div>
                          )}
                        </td>
                        <td className="py-2 pl-3 align-top">
                          {r.status === 'submitted' && disputing !== r.declaration_id && (
                            <div className="flex items-center gap-1.5">
                              <button
                                onClick={() => review(r.declaration_id, 'approve', null)} disabled={busy}
                                className="inline-flex items-center gap-1 px-2 py-1 text-xs bg-green-600 hover:bg-green-700 disabled:opacity-60 text-white rounded-lg font-medium"
                              >
                                <Check size={13} /> Goedkeuren
                              </button>
                              <button
                                onClick={() => { setDisputing(r.declaration_id); setDisputeNote(''); }} disabled={busy}
                                className="px-2 py-1 text-xs border border-slate-300 rounded-lg hover:border-slate-400 disabled:opacity-60"
                              >
                                Betwisten
                              </button>
                            </div>
                          )}

                          {disputing === r.declaration_id && (
                            <div className="flex items-center gap-1.5">
                              <input
                                type="text" value={disputeNote} autoFocus disabled={busy}
                                placeholder="Waarom?"
                                onChange={(e) => setDisputeNote(e.target.value)}
                                onKeyDown={(e) => {
                                  if (e.key === 'Enter' && disputeNote.trim()) review(r.declaration_id, 'dispute', disputeNote.trim());
                                  if (e.key === 'Escape') setDisputing(null);
                                }}
                                className="w-40 border border-slate-300 rounded-lg px-2 py-1 text-xs bg-white"
                              />
                              <button
                                onClick={() => review(r.declaration_id, 'dispute', disputeNote.trim())}
                                disabled={busy || !disputeNote.trim()}
                                className="px-2 py-1 text-xs bg-red-600 hover:bg-red-700 disabled:opacity-40 text-white rounded-lg font-medium"
                              >
                                Betwisten
                              </button>
                            </div>
                          )}

                          {(r.status === 'approved' || r.status === 'disputed') && (
                            <button
                              onClick={() => review(r.declaration_id, 'reopen', null)} disabled={busy}
                              className="inline-flex items-center gap-1 px-2 py-1 text-xs text-slate-500 hover:text-slate-800 disabled:opacity-60"
                              title="Terugzetten, zodat de koerier het opnieuw kan invullen"
                            >
                              <Undo2 size={13} /> Heropenen
                            </button>
                          )}

                          {r.status === 'open' && (
                            <span className="text-xs text-slate-400">wacht op de koerier</span>
                          )}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}

          {/* Twee dingen die je één keer moet lezen en daarna weet. Permanent in
              beeld kosten ze elke keer ruimte onder de tabel; ingeklapt blijven
              ze opvraagbaar op de plek waar de vraag opkomt. <details> is
              native, dus geen state en gewoon toetsenbord-bedienbaar. */}
          <details className="group">
            <summary className="inline-flex cursor-pointer list-none items-center gap-1.5 text-xs text-slate-400 hover:text-slate-600 [&::-webkit-details-marker]:hidden">
              <Info size={13} />
              Hoe lees ik dit overzicht?
            </summary>
            <div className="mt-2 space-y-2 border-l-2 border-slate-100 pl-3 text-xs text-slate-500">
              {/* De termijn komt uit de rijen mee en staat nergens in deze code,
                  dus zonder rijen is er ook geen getal om te noemen. */}
              {shown.length > 0 && (
                <p>
                  De verwachting is dat een koerier binnen {shown[0].expected_within_hours} uur na zijn
                  dienst doorgeeft; buiten die termijn staat amber. Het is geen grens — de invullink blijft
                  werken, en te laat ingevuld is nog altijd ingevuld.
                </p>
              )}
              <p>
                Bij eigen auto geeft de koerier zelf de kilometers op; dat is niet controleerbaar en zo bedoeld.
                Het berekende getal ernaast is een referentie om afwijkingen te zien, geen afkeuringsgrond.
              </p>
              <p>
                <strong>Onkosten</strong> zijn posten die geen kilometervergoeding zijn — parkeren, een
                veerpont, een OV-kaartje. <strong>Bon verwacht</strong> betekent dat deze koerier de bon
                per mail moet nasturen. Dat is een signaal, geen blokkade: je kunt gewoon goedkeuren.
              </p>
            </div>
          </details>
        </div>
      </div>
    </div>
  );
}
