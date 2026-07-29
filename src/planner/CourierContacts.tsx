import { useEffect, useMemo, useState } from 'react';
import { AlertTriangle, Check, Phone, Trash2, X } from 'lucide-react';
import { Courier, CourierContact } from '../types';
import { getCouriers } from './plannerService';
import {
  deleteContact, getContacts, getCouriersWithUpcomingShifts, normalizePhone, phoneWarning, saveContact,
} from './contactService';

interface Props {
  onClose: () => void;
}

// Beheerscherm voor de mobiele nummers van koeriers (migratie 011).
// Schrijft rechtstreeks met de plannersessie: de RLS-policy op courier_contacts
// staat is_privileged() toe, dus hier is géén service-role of serverfunctie voor
// nodig. Nummers komen uit een ander systeem en worden hier met de hand ingevoerd.
export default function CourierContacts({ onClose }: Props) {
  const [couriers, setCouriers] = useState<Courier[]>([]);
  const [contacts, setContacts] = useState<CourierContact[]>([]);
  const [upcoming, setUpcoming] = useState<Set<string>>(new Set());
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  // Bewerkte, nog niet opgeslagen invoer per koerier (courierId → ruwe tekst).
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [busyId, setBusyId] = useState<string | null>(null);
  const [rowError, setRowError] = useState<Record<string, string>>({});
  const [savedId, setSavedId] = useState<string | null>(null);

  async function reload() {
    setLoading(true);
    try {
      const [cs, cts, up] = await Promise.all([
        getCouriers(), getContacts(), getCouriersWithUpcomingShifts(),
      ]);
      setCouriers(cs);
      setContacts(cts);
      setUpcoming(up);
      setDrafts({});
      setError('');
    } catch (e: any) {
      setError(e?.message ?? 'Laden mislukt.');
    } finally {
      setLoading(false);
    }
  }
  useEffect(() => { reload(); }, []);

  const byCourier = useMemo(
    () => new Map(contacts.map((c) => [c.courierId, c])), [contacts],
  );

  const missingWithShifts = useMemo(
    () => couriers.filter((c) => !byCourier.has(c.id) && upcoming.has(c.id)),
    [couriers, byCourier, upcoming],
  );

  function currentValue(courierId: string): string {
    return drafts[courierId] ?? byCourier.get(courierId)?.phoneE164 ?? '';
  }

  function isDirty(courierId: string): boolean {
    if (!(courierId in drafts)) return false;
    return drafts[courierId].trim() !== (byCourier.get(courierId)?.phoneE164 ?? '');
  }

  async function save(courierId: string) {
    const raw = currentValue(courierId).trim();
    setRowError((m) => ({ ...m, [courierId]: '' }));

    // Leeg opslaan = nummer weghalen. Expliciet, zodat een per ongeluk gewist
    // veld niet stilzwijgend als "geen SMS meer" wordt geïnterpreteerd.
    if (!raw) {
      setRowError((m) => ({ ...m, [courierId]: 'Leeg — gebruik de prullenbak om het nummer te verwijderen.' }));
      return;
    }

    const parsed = normalizePhone(raw);
    if (!parsed.ok) {
      setRowError((m) => ({ ...m, [courierId]: parsed.reason }));
      return;
    }

    setBusyId(courierId);
    try {
      await saveContact(courierId, parsed.e164, null);
      setSavedId(courierId);
      setTimeout(() => setSavedId((id) => (id === courierId ? null : id)), 2000);
      await reload();
    } catch (e: any) {
      setRowError((m) => ({ ...m, [courierId]: e?.message ?? 'Opslaan mislukt.' }));
    } finally {
      setBusyId(null);
    }
  }

  async function remove(courierId: string) {
    setBusyId(courierId);
    setRowError((m) => ({ ...m, [courierId]: '' }));
    try {
      await deleteContact(courierId);
      await reload();
    } catch (e: any) {
      setRowError((m) => ({ ...m, [courierId]: e?.message ?? 'Verwijderen mislukt.' }));
    } finally {
      setBusyId(null);
    }
  }

  return (
    <div className="fixed inset-0 bg-black/40 flex items-start justify-center p-4 overflow-y-auto" onClick={onClose}>
      <div className="bg-white rounded-xl shadow-lg w-full max-w-2xl my-8" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between px-5 py-3 border-b border-slate-200">
          <h2 className="font-semibold text-slate-800 inline-flex items-center gap-2">
            <Phone size={16} className="text-green-700" /> Telefoonnummers koeriers
          </h2>
          <button onClick={onClose} className="text-slate-400 hover:text-slate-700"><X size={18} /></button>
        </div>

        <div className="p-5 space-y-4">
          {error && <p className="text-sm text-red-600">{error}</p>}
          {loading && <p className="text-sm text-slate-500">Laden…</p>}

          {!loading && missingWithShifts.length > 0 && (
            <div className="flex items-start gap-2 rounded-lg bg-amber-50 border border-amber-200 text-amber-800 text-sm p-3">
              <AlertTriangle size={15} className="mt-0.5 shrink-0" />
              <span>
                {missingWithShifts.length === 1 ? 'Eén koerier heeft' : `${missingWithShifts.length} koeriers hebben`} een
                bevestigde dienst in de komende twee weken maar géén nummer:{' '}
                <strong>{missingWithShifts.map((c) => c.name).join(', ')}</strong>. Die {missingWithShifts.length === 1 ? 'krijgt' : 'krijgen'} geen herinnering.
              </span>
            </div>
          )}

          {!loading && couriers.length === 0 && (
            <p className="text-sm text-slate-500">Geen koeriers gevonden.</p>
          )}

          <ul className="divide-y divide-slate-100">
            {couriers.map((c) => {
              const existing = byCourier.get(c.id);
              const value = currentValue(c.id);
              const dirty = isDirty(c.id);
              const busy = busyId === c.id;
              const err = rowError[c.id];
              const parsed = value.trim() ? normalizePhone(value) : null;
              const warn = parsed?.ok ? phoneWarning(parsed.e164) : null;

              return (
                <li key={c.id} className="py-2.5">
                  <div className="flex items-center gap-3">
                    <div className="min-w-0 flex-1">
                      <span className="text-sm font-medium text-slate-800">{c.name}</span>
                      {!existing && upcoming.has(c.id) && (
                        <span className="ml-2 rounded bg-amber-100 text-amber-800 text-[10px] font-semibold px-1.5 py-0.5">
                          dienst gepland
                        </span>
                      )}
                    </div>
                    <input
                      type="tel"
                      inputMode="tel"
                      value={value}
                      placeholder="06 12 34 56 78"
                      disabled={busy}
                      onChange={(e) => setDrafts((d) => ({ ...d, [c.id]: e.target.value }))}
                      onKeyDown={(e) => { if (e.key === 'Enter' && dirty) save(c.id); }}
                      className="w-48 border border-slate-300 rounded-lg px-2 py-1.5 text-sm tabular-nums bg-white disabled:opacity-60"
                    />
                    <div className="w-24 shrink-0 flex items-center justify-end gap-2">
                      {dirty && (
                        <button
                          onClick={() => save(c.id)} disabled={busy}
                          className="px-2.5 py-1 text-sm bg-green-600 hover:bg-green-700 disabled:opacity-60 text-white rounded-lg font-medium"
                        >
                          {busy ? '…' : 'Opslaan'}
                        </button>
                      )}
                      {!dirty && savedId === c.id && (
                        <span className="inline-flex items-center gap-1 text-sm text-green-700"><Check size={15} /> Opgeslagen</span>
                      )}
                      {!dirty && savedId !== c.id && existing && (
                        <button
                          onClick={() => remove(c.id)} disabled={busy}
                          className="text-slate-400 hover:text-red-600 disabled:opacity-60"
                          title="Nummer verwijderen"
                        >
                          <Trash2 size={15} />
                        </button>
                      )}
                    </div>
                  </div>

                  {err && <p className="text-xs text-red-600 mt-1">{err}</p>}
                  {!err && warn && <p className="text-xs text-amber-600 mt-1">{warn}</p>}
                  {!err && !warn && dirty && parsed?.ok && parsed.e164 !== value.trim() && (
                    <p className="text-xs text-slate-400 mt-1">Wordt opgeslagen als {parsed.e164}</p>
                  )}
                </li>
              );
            })}
          </ul>

          <p className="text-xs text-slate-400">
            Alleen planners zien deze nummers; koeriers hebben geen toegang tot deze gegevens — ook niet tot hun eigen
            nummer. Nummers worden opgeslagen als +316… Een koerier zonder nummer krijgt geen herinnering.
          </p>
        </div>
      </div>
    </div>
  );
}
