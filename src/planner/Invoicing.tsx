import { useEffect, useMemo, useRef, useState } from 'react';
import { AlertTriangle, ChevronDown, Download, Info, Receipt, X } from 'lucide-react';
import { Chain, InvoiceLine, Pharmacy } from '../types';
import { getPharmacies } from './plannerService';
import {
  amount, euro, exportInvoiceLinesToExcel, getChainInvoiceLines, getChains, getInvoiceLines, hoursText,
  InvoiceTotals, sumLines,
} from './invoiceService';
import { TYPE_STYLES } from './constants';

interface Props {
  onClose: () => void;
}

// Eerste dag van de vorige maand en de laatste dag daarvan — de periode waarover
// je normaal factureert als je aan het begin van een maand zit.
function lastMonth(): { from: string; to: string } {
  const now = new Date();
  const first = new Date(now.getFullYear(), now.getMonth() - 1, 1);
  const last = new Date(now.getFullYear(), now.getMonth(), 0);
  const iso = (d: Date) =>
    `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  return { from: iso(first), to: iso(last) };
}

// Eén blok in het overzicht: een apotheek (filiaalmodus) of de hele keten.
interface Section {
  key: string;
  name: string;
  lines: InvoiceLine[];
}

// Factuuroverzicht per apotheek per periode (fase 7, migratie 025).
//
// Dit genereert géén factuur en verstuurt niets: het is een overzicht waar een
// factuur op gebaseerd kan worden. invoice_lines() levert de bedragen al
// uitgerekend aan, dus er staat hier geen tarief, geen starttarief en geen
// verdeelregel — een tariefwijziging in de database werkt vanzelf door.
export default function Invoicing({ onClose }: Props) {
  const [pharmacies, setPharmacies] = useState<Pharmacy[]>([]);
  // Aangevinkte apotheken. Bij openen leeg: je kiest bewust voor wie je een
  // overzicht maakt, in plaats van eerst tientallen apotheken te laden.
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
  const [showPicker, setShowPicker] = useState(false);
  const pickerRef = useRef<HTMLDivElement>(null);
  // Aan wie factureren we: het filiaal of de keten. Alleen zinvol bij een
  // keten met de splitsing aan; anders staat er in de ketenkolom overal 0.
  const [chains, setChains] = useState<Chain[]>([]);
  const [mode, setMode] = useState<'pharmacy' | 'chain'>('pharmacy');
  const [chainId, setChainId] = useState('');
  const [period, setPeriod] = useState(lastMonth);
  const [sections, setSections] = useState<Section[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    Promise.all([getPharmacies(), getChains()])
      .then(([ps, cs]) => {
        setPharmacies(ps);
        setChains(cs);
        const split = cs.filter((c) => c.split_extra_work);
        if (split.length > 0) setChainId((cur) => cur || split[0].group_id);
      })
      .catch((e: any) => setError(e?.message ?? 'Apotheken laden mislukt.'));
  }, []);

  const chainName = useMemo(
    () => chains.find((c) => c.group_id === chainId)?.group_name ?? '', [chains, chainId]);

  useEffect(() => {
    if (!showPicker) return;
    function onMouseDown(e: MouseEvent) {
      if (!pickerRef.current?.contains(e.target as Node)) setShowPicker(false);
    }
    document.addEventListener('mousedown', onMouseDown);
    return () => document.removeEventListener('mousedown', onMouseDown);
  }, [showPicker]);

  // In de volgorde van getPharmacies(), dus op naam.
  const selected = useMemo(
    () => pharmacies.filter((p) => selectedIds.has(p.id)), [pharmacies, selectedIds]);
  // Stabiele sleutel voor het laden: een nieuwe Set met dezelfde inhoud mag
  // niet opnieuw alle aanroepen afvuren.
  const selectedKey = selected.map((p) => p.id).join(',');

  useEffect(() => {
    let cancelled = false;
    setLoading(true);

    const load: Promise<Section[]> = mode === 'chain'
      ? getChainInvoiceLines(
          pharmacies.filter((p) => p.groupId === chainId).map((p) => p.id),
          period.from, period.to)
          .then((rows) => [{ key: chainId, name: `${chainName} (centraal)`, lines: rows }])
      // Eén aanroep per apotheek, tegelijk, zoals de ketenfactuur dat al doet.
      // Een apotheek zonder regels in de periode krijgt geen blok.
      : Promise.all(selected.map((p) =>
          getInvoiceLines(p.id, period.from, period.to)
            .then((rows) => ({ key: p.id, name: p.name, lines: rows }))))
          .then((all) => all.filter((sec) => sec.lines.length > 0));

    load
      .then((rows) => { if (!cancelled) { setSections(rows); setError(''); } })
      .catch((e: any) => { if (!cancelled) { setSections([]); setError(e?.message ?? 'Laden mislukt.'); } })
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  // selected zit via selectedKey in de afhankelijkheden.
  }, [mode, selectedKey, chainId, chainName, pharmacies, period.from, period.to]);

  const lines = useMemo(() => sections.flatMap((sec) => sec.lines), [sections]);
  const totals = useMemo(() => sumLines(lines), [lines]);
  const splitChains = useMemo(() => chains.filter((c) => c.split_extra_work), [chains]);
  // In ketenmodus telt alleen het ketendeel; op een filiaalfactuur alleen het
  // filiaaldeel. Zonder splitsing is dat laatste gewoon het hele bedrag.
  const invoiceTotal = (t: InvoiceTotals) => (mode === 'chain' ? t.chain : t.branch);

  const pickerLabel = selected.length === 0
    ? 'Geen apotheken'
    : selected.length === 1
      ? selected[0].name
      : `${selected.length} apotheken geselecteerd`;

  function togglePharmacy(id: string) {
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  }

  return (
    <div className="fixed inset-0 z-50 bg-black/40 flex items-start justify-center p-4 overflow-y-auto" onClick={onClose}>
      <div
        className="bg-white rounded-xl shadow-lg w-full max-w-[95vw] xl:max-w-[88rem] my-8"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between px-5 py-3 border-b border-slate-200">
          <h2 className="font-semibold text-slate-800 inline-flex items-center gap-2">
            <Receipt size={16} className="text-green-700" /> Facturatie
          </h2>
          <button onClick={onClose} className="text-slate-400 hover:text-slate-700"><X size={18} /></button>
        </div>

        <div className="p-5 space-y-4">
          <div className="flex flex-wrap items-center gap-3 text-sm">
            {/* Factureren aan het filiaal of aan de keten. De ketenkeuze
                verschijnt alleen als er een keten mét splitsing is; anders is er
                niets te kiezen en zou hij verwarren. */}
            {splitChains.length > 0 && (
              <div className="inline-flex rounded-lg border border-slate-300 overflow-hidden">
                {([
                  ['pharmacy', 'Filiaal'],
                  ['chain', 'Keten'],
                ] as const).map(([key, label]) => (
                  <button
                    key={key} onClick={() => setMode(key)}
                    className={`px-2.5 py-1 ${
                      mode === key ? 'bg-green-600 text-white' : 'bg-white text-slate-600 hover:bg-slate-50'
                    }`}
                  >
                    {label}
                  </button>
                ))}
              </div>
            )}

            {mode === 'chain' ? (
              <label className="inline-flex items-center gap-1.5">
                <span className="text-slate-500">Keten</span>
                <select
                  value={chainId} onChange={(e) => setChainId(e.target.value)}
                  className="border border-slate-300 rounded-lg px-2 py-1 bg-white"
                >
                  {splitChains.map((c) => (
                    <option key={c.group_id} value={c.group_id}>{c.group_name}</option>
                  ))}
                </select>
              </label>
            ) : (
              <div ref={pickerRef} className="relative inline-flex items-center gap-1.5">
                <span className="text-slate-500">Apotheken</span>
                <button
                  onClick={() => setShowPicker((v) => !v)}
                  className="inline-flex items-center gap-1 border border-slate-300 rounded-lg px-2 py-1 bg-white hover:bg-slate-50 max-w-[18rem]"
                  aria-expanded={showPicker}
                >
                  <span className="truncate">{pickerLabel}</span>
                  <ChevronDown size={14} className="shrink-0" />
                </button>
                {showPicker && (
                  <div className="absolute left-0 top-full mt-1 z-50 w-72 bg-white border border-slate-200 rounded-lg shadow-lg">
                    <div className="flex gap-3 px-3 py-2 border-b border-slate-100 text-xs">
                      <button onClick={() => setSelectedIds(new Set(pharmacies.map((p) => p.id)))}
                        className="text-green-700 hover:underline">Alles selecteren</button>
                      <button onClick={() => setSelectedIds(new Set())}
                        className="text-slate-600 hover:underline">Alles deselecteren</button>
                    </div>
                    <div className="max-h-72 overflow-y-auto py-1">
                      {pharmacies.map((p) => (
                        <label key={p.id} className="flex items-center gap-2 px-3 py-1 hover:bg-slate-50 cursor-pointer">
                          <input type="checkbox" checked={selectedIds.has(p.id)} onChange={() => togglePharmacy(p.id)} />
                          <span className="truncate">{p.name}</span>
                        </label>
                      ))}
                    </div>
                  </div>
                )}
              </div>
            )}
            <label className="inline-flex items-center gap-1.5">
              <span className="text-slate-500">Van</span>
              <input
                type="date" value={period.from}
                onChange={(e) => setPeriod((p) => ({ ...p, from: e.target.value }))}
                className="border border-slate-300 rounded-lg px-2 py-1 bg-white"
              />
            </label>
            <label className="inline-flex items-center gap-1.5">
              <span className="text-slate-500">t/m</span>
              <input
                type="date" value={period.to}
                onChange={(e) => setPeriod((p) => ({ ...p, to: e.target.value }))}
                className="border border-slate-300 rounded-lg px-2 py-1 bg-white"
              />
            </label>
            <button
              onClick={() => setPeriod(lastMonth())}
              className="text-slate-600 hover:text-slate-900 underline"
            >
              Vorige maand
            </button>
            {!loading && lines.length > 0 && (
              <button
                onClick={() => exportInvoiceLinesToExcel(lines, pharmacies, mode, period)}
                className="inline-flex items-center gap-1.5 rounded-lg px-3 py-1 bg-green-700 text-white hover:bg-green-800"
                title="Download de geladen regels als Excel, één tabblad per apotheek"
              >
                <Download size={14} /> Exporteren
              </button>
            )}
          </div>

          {error && <p className="text-sm text-red-600">{error}</p>}
          {loading && <p className="text-sm text-slate-500">Regels laden…</p>}

          {!loading && totals.incomplete > 0 && (
            <div className="flex items-start gap-2 rounded-lg bg-amber-50 border border-amber-200 text-amber-800 text-sm p-3">
              <AlertTriangle size={15} className="mt-0.5 shrink-0" />
              <span>
                {totals.incomplete === 1 ? 'Eén regel heeft' : `${totals.incomplete} regels hebben`} een
                markering — de reden staat in de regel zelf.
                {totals.withoutTotal > 0 && (
                  <> {totals.withoutTotal === 1 ? 'Eén regel heeft' : `${totals.withoutTotal} regels hebben`} géén
                  bedrag en telt dus niet mee in het totaal.</>
                )}
              </span>
            </div>
          )}

          {!loading && lines.length === 0 && !error && (
            <p className="text-sm text-slate-500">
              {mode === 'pharmacy' && selected.length === 0
                ? 'Geen apotheken geselecteerd.'
                : 'Geen diensten voor de gekozen apotheken in deze periode. Concepten tellen niet mee.'}
            </p>
          )}

          {sections.map((sec) => {
            const secTotals = sumLines(sec.lines);
            return (
            <div key={sec.key} className="overflow-x-auto">
              {mode === 'pharmacy' && sections.length > 1 && (
                <h3 className="text-sm font-semibold text-slate-800 pt-2 pb-1">{sec.name}</h3>
              )}
              <table className="w-full min-w-[78rem] text-sm">
                <thead>
                  <tr className="text-left text-xs uppercase tracking-wide text-slate-500 border-b border-slate-200">
                    <th className="py-2 pr-3 font-medium">Datum</th>
                    <th className="py-2 px-3 font-medium">Koerier</th>
                    <th className="py-2 px-3 font-medium">Type</th>
                    <th className="py-2 px-3 font-medium text-right">Gepland</th>
                    <th className="py-2 px-3 font-medium text-right">Werkelijk</th>
                    <th className="py-2 px-3 font-medium text-right">Aandeel</th>
                    {/* Het euroteken staat hier en op de totaalregel, niet in elke
                        cel: vijf bedragkolommen naast elkaar hebben die breedte
                        niet, en te weinig breedte betekent een afgebroken bedrag
                        met het teken bóven het getal. */}
                    <th className="py-2 px-3 font-medium text-right whitespace-nowrap min-w-[6rem]">Uren (€)</th>
                    <th className="py-2 px-3 font-medium text-right whitespace-nowrap min-w-[5.5rem]">Start (€)</th>
                    <th className="py-2 px-3 font-medium text-right whitespace-nowrap min-w-[5.5rem]">Reis (€)</th>
                    <th className="py-2 px-3 font-medium text-right whitespace-nowrap min-w-[6rem]">Onkosten (€)</th>
                    <th className="py-2 px-3 font-medium text-right whitespace-nowrap min-w-[5.5rem]">Spoed (€)</th>
                    <th className="py-2 pl-3 font-medium text-right whitespace-nowrap min-w-[6.5rem]">Totaal (€)</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {sec.lines.map((l) => (
                    <tr key={`${l.shift_id}`} className={l.incomplete ? 'bg-amber-50/60' : undefined}>
                      <td className="py-2 pr-3 align-top tabular-nums whitespace-nowrap">{l.shift_date}</td>
                      <td className="py-2 px-3 align-top">
                        <span className="whitespace-nowrap">{l.courier_name ?? 'Open'}</span>
                      </td>
                      <td className="py-2 px-3 align-top">
                        <span className={`rounded px-1.5 py-0.5 text-[11px] font-semibold ${TYPE_STYLES[l.shift_type].bg} ${TYPE_STYLES[l.shift_type].text}`}>
                          {TYPE_STYLES[l.shift_type].label}
                        </span>
                        {/* Toelichting en markering mogen wél afbreken — dat is
                            tekst. Met een maximum, anders duwt één lange reden de
                            bedragkolommen de tabel uit. */}
                        {l.urgent_note && (
                          <div className="text-xs text-slate-500 mt-0.5 italic max-w-[20rem]">“{l.urgent_note}”</div>
                        )}
                        {l.incomplete && (
                          <div className="text-xs text-amber-700 mt-0.5 max-w-[20rem]">{l.reason}</div>
                        )}
                        {/* Goedgekeurd en verlopen leveren allebei een regel op;
                            alleen bij het tweede heeft nooit iemand gekeken, en
                            dat is precies waar discussie uit voortkomt. */}
                        {l.extra_work_status === 'approved' && (
                          <div className="text-xs text-green-700 mt-0.5">meerwerk goedgekeurd</div>
                        )}
                        {l.extra_work_status === 'expired' && (
                          <div className="text-xs text-slate-500 mt-0.5">meerwerk: geen reactie</div>
                        )}
                      </td>
                      <td className="py-2 px-3 align-top text-right tabular-nums whitespace-nowrap">
                        {hoursText(l.planned_minutes)}
                      </td>
                      <td className="py-2 px-3 align-top text-right tabular-nums whitespace-nowrap">
                        {hoursText(l.billed_minutes)}
                        {!l.from_declaration && (
                          <div className="text-xs text-amber-700">gepland</div>
                        )}
                      </td>
                      <td className="py-2 px-3 align-top text-right tabular-nums whitespace-nowrap">
                        {l.pharmacies_in_shift > 1 ? `${Number(l.share_pct).toFixed(0)}%` : '—'}
                      </td>
                      <td className="py-2 px-3 align-top text-right tabular-nums whitespace-nowrap">
                        {amount(l.hours_amount)}
                        {l.hourly_rate != null && (
                          <div className="text-xs text-slate-400 whitespace-nowrap">{amount(l.hourly_rate)}/u</div>
                        )}
                      </td>
                      <td className="py-2 px-3 align-top text-right tabular-nums whitespace-nowrap">{amount(l.start_amount)}</td>
                      <td className="py-2 px-3 align-top text-right tabular-nums whitespace-nowrap">{amount(l.travel_amount)}</td>
                      <td className="py-2 px-3 align-top text-right tabular-nums whitespace-nowrap">{amount(l.expenses_amount)}</td>
                      <td className="py-2 px-3 align-top text-right tabular-nums whitespace-nowrap">{amount(l.urgent_amount)}</td>
                      <td className="py-2 pl-3 align-top text-right tabular-nums whitespace-nowrap font-medium">
                        {/* In ketenmodus staat hier het ketendeel, anders het deel
                            dat naar dit filiaal gaat. Zonder splitsing zijn die
                            twee hetzelfde als het regeltotaal. */}
                        {amount(mode === 'chain' ? l.chain_amount : l.branch_amount)}
                        {l.split_active && (
                          <div className="text-xs font-normal text-slate-400">
                            van {amount(l.line_total)}
                          </div>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
                <tfoot>
                  <tr className="border-t-[3px] border-slate-800 bg-slate-50 font-semibold text-slate-900">
                    <td className="py-2.5 pr-3" colSpan={4}>
                      {sec.lines.length} regel{sec.lines.length === 1 ? '' : 's'} · {sec.name}
                      {mode === 'chain' && secTotals.branch > 0 && (
                        <span className="font-normal text-slate-500">
                          {' '}— {euro(secTotals.branch)} gaat naar de filialen
                        </span>
                      )}
                    </td>
                    <td className="py-2.5 px-3 text-right tabular-nums whitespace-nowrap">{hoursText(secTotals.billedMinutes)}</td>
                    <td className="py-2.5 px-3"></td>
                    <td className="py-2.5 px-3 text-right tabular-nums whitespace-nowrap">{euro(secTotals.hours)}</td>
                    <td className="py-2.5 px-3 text-right tabular-nums whitespace-nowrap">{euro(secTotals.start)}</td>
                    <td className="py-2.5 px-3 text-right tabular-nums whitespace-nowrap">{euro(secTotals.travel)}</td>
                    <td className="py-2.5 px-3 text-right tabular-nums whitespace-nowrap">{euro(secTotals.expenses)}</td>
                    <td className="py-2.5 px-3 text-right tabular-nums whitespace-nowrap">{euro(secTotals.urgent)}</td>
                    <td className="py-2.5 pl-3 text-right tabular-nums whitespace-nowrap text-base">{euro(invoiceTotal(secTotals))}</td>
                  </tr>
                </tfoot>
              </table>
            </div>
            );
          })}

          {/* Eindtotaal over alle apotheken. Alleen bij meer dan één blok; bij
              één staat hetzelfde getal al onder de tabel. */}
          {mode === 'pharmacy' && sections.length > 1 && (
            <div className="flex flex-wrap items-baseline justify-between gap-2 rounded-lg bg-slate-800 text-white px-4 py-3">
              <span className="text-sm">
                Totaal {sections.length} apotheken · {lines.length} regel{lines.length === 1 ? '' : 's'} ·{' '}
                {hoursText(totals.billedMinutes)} uur
              </span>
              <span className="text-lg font-semibold tabular-nums">{euro(invoiceTotal(totals))}</span>
            </div>
          )}

          <details className="group">
            <summary className="inline-flex cursor-pointer list-none items-center gap-1.5 text-xs text-slate-400 hover:text-slate-600 [&::-webkit-details-marker]:hidden">
              <Info size={13} />
              Hoe komen deze bedragen tot stand?
            </summary>
            <div className="mt-2 space-y-2 border-l-2 border-slate-100 pl-3 text-xs text-slate-500">
              <p>
                <strong>Uren</strong> gaan naar rato van de geplande minuten per apotheek. Loopt een
                dienst uit, dan krijgt elke apotheek een evenredig deel van de uitloop; is de koerier
                eerder klaar, dan evenredig minder. Bij één apotheek gaat de volledige duur daarheen.
              </p>
              <p>
                Het <strong>starttarief</strong> wordt niet verdeeld: elke apotheek in een gedeelde
                dienst krijgt er een volledige, want voor die apotheek is het een eigen opdracht.
                <strong> Reiskosten</strong> en <strong>onkosten</strong> volgen wél dezelfde
                verhouding als de uren.
              </p>
              <p>
                <strong>Onkosten</strong> zijn wat de koerier voorschoot — parkeren, een veerpont, een
                OV-kaartje — en worden <strong>zonder marge</strong> doorbelast. Ze staan los van de
                kilometervergoeding.
              </p>
              <p>
                Bij <strong>spoed</strong> telt alleen het telefonisch afgesproken bedrag — geen uren,
                geen starttarief. De koerier krijgt zijn uren gewoon via de declaratie.
              </p>
              <p>
                Staat bij een keten de <strong>splitsing</strong> aan, dan gaan de gebudgetteerde uren
                en het starttarief naar het centrale adres en blijven het goedgekeurde meerwerk, de
                reiskosten, de onkosten en spoed bij het filiaal. Het bedrag in de laatste kolom is
                het deel voor de gekozen ontvanger; eronder staat het regeltotaal.
              </p>
              <p>
                Amber betekent: er ontbrak iets, of er is iets opvallends. De regel wordt wel
                berekend met wat er is. Dit is een overzicht om een factuur op te baseren, geen
                factuur.
              </p>
            </div>
          </details>
        </div>
      </div>
    </div>
  );
}
