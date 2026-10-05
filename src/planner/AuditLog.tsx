import { useEffect, useMemo, useState } from 'react';
import { ChevronDown, ChevronRight, Database, History, X } from 'lucide-react';
import { Courier } from '../types';
import { getCouriers } from './plannerService';
import {
  actorOf, ActorTone, AuditActor, AuditFilters, AuditGroup, AuditKind, AuditRow, diffFields,
  fieldLabel, getAuditActors, getAuditLog, groupByTx, groupSentence, KIND_LABELS, PAGE_SIZE,
  rowSentence, timestampShort,
} from './auditService';

interface Props {
  onClose: () => void;
}

function isoDaysAgo(n: number): string {
  const d = new Date();
  d.setDate(d.getDate() - n);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

// Wie het was, en hoe dat eruitziet. SQL valt het meest op: dat is de reden dat
// dit scherm bestaat — op 3 oktober werden elf diensten zo bevestigd zonder dat
// iemand het achteraf kon terugvinden.
const TONE: Record<ActorTone, string> = {
  planner: 'font-medium text-slate-800',
  courier: 'font-medium text-blue-700',
  system:  'text-slate-500',
  sql:     'inline-flex items-center gap-1 rounded bg-amber-100 px-1.5 py-0.5 text-xs font-semibold text-amber-900',
  unknown: 'rounded bg-red-100 px-1.5 py-0.5 text-xs font-semibold text-red-800',
};

// Logboek: wie heeft wat wanneer gewijzigd (migratie 056). Alleen voor superusers;
// de database weigert iedereen anders ook, dus het verbergen van het menu-item is
// gemak en geen beveiliging.
export default function AuditLog({ onClose }: Props) {
  const [filters, setFilters] = useState<AuditFilters>({
    from: isoDaysAgo(7), to: isoDaysAgo(0), kind: '', who: '', courierId: '',
    search: '', showCouriers: false, showSystem: false,
  });
  // Het zoekveld apart, zodat niet elke toetsaanslag een verzoek wordt.
  const [searchInput, setSearchInput] = useState('');

  const [rows, setRows] = useState<AuditRow[]>([]);
  const [hasMore, setHasMore] = useState(false);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState('');

  const [actors, setActors] = useState<AuditActor[]>([]);
  const [couriers, setCouriers] = useState<Courier[]>([]);

  const [openGroups, setOpenGroups] = useState<Set<number>>(new Set());
  const [openRows, setOpenRows] = useState<Set<number>>(new Set());

  const set = <K extends keyof AuditFilters>(k: K, v: AuditFilters[K]) =>
    setFilters((f) => ({ ...f, [k]: v }));

  useEffect(() => {
    const t = setTimeout(() => setFilters((f) => (f.search === searchInput ? f : { ...f, search: searchInput })), 400);
    return () => clearTimeout(t);
  }, [searchInput]);

  useEffect(() => {
    getCouriers().then((list) => setCouriers([...list].sort((a, b) => a.name.localeCompare(b.name)))).catch(() => {});
  }, []);

  useEffect(() => {
    getAuditActors(filters.from, filters.to).then(setActors).catch(() => setActors([]));
  }, [filters.from, filters.to]);

  // Elke filterwijziging begint opnieuw bovenaan. Doorbladeren met oude
  // filters en dan nieuwe regels eronder plakken zou een lijst opleveren die
  // bij geen enkele filter hoort.
  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setOpenGroups(new Set());
    setOpenRows(new Set());
    getAuditLog(filters, null)
      .then((list) => {
        if (cancelled) return;
        setRows(list);
        setHasMore(list.length === PAGE_SIZE);
        setError('');
      })
      .catch((e: any) => { if (!cancelled) setError(e?.message ?? 'Laden mislukt.'); })
      .finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [filters]);

  async function loadMore() {
    if (rows.length === 0) return;
    setLoadingMore(true);
    try {
      const list = await getAuditLog(filters, rows[rows.length - 1].id);
      setRows((prev) => [...prev, ...list]);
      setHasMore(list.length === PAGE_SIZE);
    } catch (e: any) {
      setError(e?.message ?? 'Laden mislukt.');
    } finally {
      setLoadingMore(false);
    }
  }

  // Opnieuw groeperen over alles wat geladen is: een transactie van 300 regels
  // loopt over drie pagina's en moet daarna nog steeds één regel zijn.
  const groups = useMemo(() => groupByTx(rows), [rows]);

  const toggle = (setFn: typeof setOpenGroups, key: number) =>
    setFn((s) => { const n = new Set(s); if (n.has(key)) n.delete(key); else n.add(key); return n; });

  return (
    <div className="fixed inset-0 z-50 bg-black/40 flex items-start justify-center p-4 overflow-y-auto" onClick={onClose}>
      <div
        className="bg-white rounded-xl shadow-lg w-full max-w-[95vw] xl:max-w-[72rem] my-8"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between px-5 py-3 border-b border-slate-200">
          <h2 className="font-semibold text-slate-800 inline-flex items-center gap-2">
            <History size={16} className="text-green-700" /> Logboek
          </h2>
          <button onClick={onClose} className="text-slate-400 hover:text-slate-700"><X size={18} /></button>
        </div>

        <div className="p-5 space-y-4">
          <div className="flex flex-wrap items-center gap-3 text-sm">
            <label className="inline-flex items-center gap-1.5">
              <span className="text-slate-500">Van</span>
              <input type="date" value={filters.from} onChange={(e) => set('from', e.target.value)}
                className="border border-slate-300 rounded-lg px-2 py-1 bg-white" />
            </label>
            <label className="inline-flex items-center gap-1.5">
              <span className="text-slate-500">t/m</span>
              <input type="date" value={filters.to} onChange={(e) => set('to', e.target.value)}
                className="border border-slate-300 rounded-lg px-2 py-1 bg-white" />
            </label>

            <select value={filters.who} onChange={(e) => set('who', e.target.value)}
              className="border border-slate-300 rounded-lg px-2 py-1 bg-white">
              <option value="">Iedereen</option>
              <option value="sql">Buiten de Planner om (SQL)</option>
              {actors.map((a) => (
                <option key={a.actor_id} value={a.actor_id}>
                  {a.actor_name ?? 'onbekend'}{a.actor_role ? ` · ${a.actor_role}` : ''}
                </option>
              ))}
            </select>

            <select value={filters.kind} onChange={(e) => set('kind', e.target.value as AuditKind | '')}
              className="border border-slate-300 rounded-lg px-2 py-1 bg-white">
              <option value="">Alle soorten</option>
              {(Object.keys(KIND_LABELS) as AuditKind[]).map((k) => (
                <option key={k} value={k}>{KIND_LABELS[k]}</option>
              ))}
            </select>

            <select value={filters.courierId} onChange={(e) => set('courierId', e.target.value)}
              className="border border-slate-300 rounded-lg px-2 py-1 bg-white max-w-[14rem]">
              <option value="">Alle koeriers</option>
              {couriers.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
            </select>

            <input type="search" value={searchInput} onChange={(e) => setSearchInput(e.target.value)}
              placeholder="Zoeken…"
              className="border border-slate-300 rounded-lg px-2 py-1 bg-white w-44" />
          </div>

          {/* Standaard alleen wat mensen in de Planner deden, plus alles wat er
              buitenom ging. Het systeem schrijft elke vijf minuten; zonder deze
              keuze verdrinkt de enige regel die ertoe doet. */}
          <div className="flex flex-wrap items-center gap-4 text-sm text-slate-600">
            <label className="inline-flex items-center gap-1.5 cursor-pointer">
              <input type="checkbox" checked={filters.showCouriers}
                onChange={(e) => set('showCouriers', e.target.checked)} />
              Toon koeriers en formulieren
            </label>
            <label className="inline-flex items-center gap-1.5 cursor-pointer">
              <input type="checkbox" checked={filters.showSystem}
                onChange={(e) => set('showSystem', e.target.checked)} />
              Toon systeem (service en cron)
            </label>
            <span className="ml-auto text-xs text-slate-400">
              {loading ? '' : `${groups.length} ${groups.length === 1 ? 'handeling' : 'handelingen'}, ${rows.length} regels`}
            </span>
          </div>

          {error && <p className="text-sm text-red-600">{error}</p>}
          {loading && <p className="text-sm text-slate-500">Laden…</p>}
          {!loading && !error && groups.length === 0 && (
            <p className="text-sm text-slate-500">Niets gevonden met deze filters.</p>
          )}

          <ul className="divide-y divide-slate-100 border border-slate-200 rounded-lg">
            {groups.map((g) => (
              <GroupItem
                key={g.txid} group={g}
                open={openGroups.has(g.txid)}
                onToggle={() => toggle(setOpenGroups, g.txid)}
                openRows={openRows}
                onToggleRow={(id) => toggle(setOpenRows, id)}
              />
            ))}
          </ul>

          {hasMore && !loading && (
            <button
              type="button" onClick={loadMore} disabled={loadingMore}
              className="w-full py-2 text-sm text-slate-600 border border-slate-200 rounded-lg hover:bg-slate-50 disabled:opacity-60"
            >
              {loadingMore ? 'Laden…' : `Meer laden (${PAGE_SIZE} regels)`}
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

function Actor({ row }: { row: AuditRow }) {
  const a = actorOf(row);
  return (
    <span className={TONE[a.tone]}>
      {a.tone === 'sql' && <Database size={11} />}
      {a.text}
    </span>
  );
}

function GroupItem({
  group: g, open, onToggle, openRows, onToggleRow,
}: {
  group: AuditGroup; open: boolean; onToggle: () => void;
  openRows: Set<number>; onToggleRow: (id: number) => void;
}) {
  const first = g.rows[0];
  const single = g.rows.length === 1 && g.total <= 1;
  const sql = first.source === 'sql';

  return (
    <li className={sql ? 'bg-amber-50/60 border-l-4 border-amber-400' : ''}>
      <button type="button" onClick={onToggle}
        className="w-full flex items-start gap-2 px-3 py-2 text-left text-sm hover:bg-slate-50">
        {open ? <ChevronDown size={15} className="mt-0.5 shrink-0 text-slate-400" />
              : <ChevronRight size={15} className="mt-0.5 shrink-0 text-slate-400" />}
        <span className="w-24 shrink-0 tabular-nums text-slate-500">{timestampShort(first.occurred_at)}</span>
        <span className="min-w-0">
          <Actor row={first} />{' '}
          <span className="text-slate-700">{groupSentence(g)}</span>
          {!single && g.rows.length < g.total && (
            <span className="ml-1 text-xs text-slate-400">({g.rows.length} van {g.total} geladen)</span>
          )}
        </span>
      </button>

      {open && (
        <div className="px-9 pb-3">
          {single ? (
            <RowDetail row={first} />
          ) : (
            <ul className="space-y-1">
              {g.rows.map((r) => (
                <li key={r.id}>
                  <button type="button" onClick={() => onToggleRow(r.id)}
                    className="flex items-start gap-1.5 text-left text-sm text-slate-700 hover:text-slate-900">
                    {openRows.has(r.id)
                      ? <ChevronDown size={14} className="mt-0.5 shrink-0 text-slate-400" />
                      : <ChevronRight size={14} className="mt-0.5 shrink-0 text-slate-400" />}
                    {rowSentence(r)}
                  </button>
                  {openRows.has(r.id) && <div className="pl-5 pt-1"><RowDetail row={r} /></div>}
                </li>
              ))}
              {g.rows.length < g.total && (
                <li className="text-xs text-slate-400">
                  Nog {g.total - g.rows.length} regels van deze handeling — laad meer om ze te zien.
                </li>
              )}
            </ul>
          )}
        </div>
      )}
    </li>
  );
}

// Per veld oud en nieuw. Plus de herkomst in ruwe vorm: wie wil nagaan waaróm
// een regel als SQL of cron is aangemerkt, vindt hier de sessienaam waarop dat
// berust.
function RowDetail({ row: r }: { row: AuditRow }) {
  const fields = diffFields(r);
  const showOld = r.action !== 'INSERT';
  const showNew = r.action !== 'DELETE';
  return (
    <div className="space-y-1.5">
      {fields.length === 0 ? (
        <p className="text-xs text-slate-400">Geen velden vastgelegd.</p>
      ) : (
        <table className="text-xs border-collapse">
          <thead>
            <tr className="text-slate-400">
              <th className="text-left font-normal pr-4">Veld</th>
              {showOld && <th className="text-left font-normal pr-4">Was</th>}
              {showNew && <th className="text-left font-normal">Wordt</th>}
            </tr>
          </thead>
          <tbody>
            {fields.map((f) => (
              <tr key={f.field} className="align-top">
                <td className="pr-4 text-slate-500 whitespace-nowrap">{fieldLabel(f.field)}</td>
                {showOld && <td className="pr-4 text-slate-500 line-through decoration-slate-300 break-all">{f.old}</td>}
                {showNew && <td className="text-slate-800 break-all">{f.new}</td>}
              </tr>
            ))}
          </tbody>
        </table>
      )}
      <p className="text-[11px] text-slate-400">
        {r.table_name} · {r.action.toLowerCase()} · bron {r.source}
        {r.app_name ? ` · sessie ${r.app_name}` : ''}
        {r.row_id ? ` · rij ${r.row_id}` : ''}
      </p>
    </div>
  );
}
