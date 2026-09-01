import { useEffect, useMemo, useState } from 'react';
import { AlertTriangle, Info, Receipt, X } from 'lucide-react';
import { Chain, InvoiceLine, Pharmacy } from '../types';
import { getPharmacies } from './plannerService';
import {
  amount, euro, getChainInvoiceLines, getChains, getInvoiceLines, hoursText, sumLines,
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

// Factuuroverzicht per apotheek per periode (fase 7, migratie 025).
//
// Dit genereert géén factuur en verstuurt niets: het is een overzicht waar een
// factuur op gebaseerd kan worden. invoice_lines() levert de bedragen al
// uitgerekend aan, dus er staat hier geen tarief, geen starttarief en geen
// verdeelregel — een tariefwijziging in de database werkt vanzelf door.
export default function Invoicing({ onClose }: Props) {
  const [pharmacies, setPharmacies] = useState<Pharmacy[]>([]);
  const [pharmacyId, setPharmacyId] = useState('');
  // Aan wie factureren we: het filiaal of de keten. Alleen zinvol bij een
  // keten met de splitsing aan; anders staat er in de ketenkolom overal 0.
  const [chains, setChains] = useState<Chain[]>([]);
  const [mode, setMode] = useState<'pharmacy' | 'chain'>('pharmacy');
  const [chainId, setChainId] = useState('');
  const [period, setPeriod] = useState(lastMonth);
  const [lines, setLines] = useState<InvoiceLine[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    Promise.all([getPharmacies(), getChains()])
      .then(([ps, cs]) => {
        setPharmacies(ps);
        setChains(cs);
        if (ps.length > 0) setPharmacyId((cur) => cur || ps[0].id);
        const split = cs.filter((c) => c.split_extra_work);
        if (split.length > 0) setChainId((cur) => cur || split[0].group_id);
      })
      .catch((e: any) => setError(e?.message ?? 'Apotheken laden mislukt.'));
  }, []);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);

    const load = mode === 'chain'
      ? getChainInvoiceLines(
          pharmacies.filter((p) => p.groupId === chainId).map((p) => p.id),
          period.from, period.to)
      : (pharmacyId ? getInvoiceLines(pharmacyId, period.from, period.to) : Promise.resolve([]));

    load
      .then((rows) => { if (!cancelled) { setLines(rows); setError(''); } })
      .catch((e: any) => { if (!cancelled) { setLines([]); setError(e?.message ?? 'Laden mislukt.'); } })
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [mode, pharmacyId, chainId, pharmacies, period.from, period.to]);

  const totals = useMemo(() => sumLines(lines), [lines]);
  const pharmacyName = useMemo(
    () => pharmacies.find((p) => p.id === pharmacyId)?.name ?? '', [pharmacies, pharmacyId]);
  const chainName = useMemo(
    () => chains.find((c) => c.group_id === chainId)?.group_name ?? '', [chains, chainId]);
  const splitChains = useMemo(() => chains.filter((c) => c.split_extra_work), [chains]);
  // In ketenmodus telt alleen het ketendeel; op een filiaalfactuur alleen het
  // filiaaldeel. Zonder splitsing is dat laatste gewoon het hele bedrag.
  const invoiceTotal = mode === 'chain' ? totals.chain : totals.branch;

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
              <label className="inline-flex items-center gap-1.5">
                <span className="text-slate-500">Apotheek</span>
                <select
                  value={pharmacyId} onChange={(e) => setPharmacyId(e.target.value)}
                  className="border border-slate-300 rounded-lg px-2 py-1 bg-white"
                >
                  {pharmacies.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
                </select>
              </label>
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
              Geen diensten voor {pharmacyName} in deze periode. Concepten tellen niet mee.
            </p>
          )}

          {lines.length > 0 && (
            <div className="overflow-x-auto">
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
                  {lines.map((l) => (
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
                      {lines.length} regel{lines.length === 1 ? '' : 's'} ·{' '}
                      {mode === 'chain' ? `${chainName} (centraal)` : pharmacyName}
                      {mode === 'chain' && totals.branch > 0 && (
                        <span className="font-normal text-slate-500">
                          {' '}— {euro(totals.branch)} gaat naar de filialen
                        </span>
                      )}
                    </td>
                    <td className="py-2.5 px-3 text-right tabular-nums whitespace-nowrap">{hoursText(totals.billedMinutes)}</td>
                    <td className="py-2.5 px-3"></td>
                    <td className="py-2.5 px-3 text-right tabular-nums whitespace-nowrap">{euro(totals.hours)}</td>
                    <td className="py-2.5 px-3 text-right tabular-nums whitespace-nowrap">{euro(totals.start)}</td>
                    <td className="py-2.5 px-3 text-right tabular-nums whitespace-nowrap">{euro(totals.travel)}</td>
                    <td className="py-2.5 px-3 text-right tabular-nums whitespace-nowrap">{euro(totals.expenses)}</td>
                    <td className="py-2.5 px-3 text-right tabular-nums whitespace-nowrap">{euro(totals.urgent)}</td>
                    <td className="py-2.5 pl-3 text-right tabular-nums whitespace-nowrap text-base">{euro(invoiceTotal)}</td>
                  </tr>
                </tfoot>
              </table>
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
