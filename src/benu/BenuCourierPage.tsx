import { useEffect, useMemo, useState } from 'react';
import { AlertTriangle, Check, Clock } from 'lucide-react';

// ── De BENU-tijdinvoer voor de koerier ────────────────────────────────────
// Achter de link uit de avondmail. Geen inlog: het token in de URL is het hele
// bewijs, net als bij de nadeclaratie en de meerwerkpagina. De pagina praat
// uitsluitend met de Edge Function benu-courier-form; de benu-tabellen hebben
// geen enkele policy en geen rechten voor anon.
//
// Eén formulier per dienst, één blok per apotheek. Wie hier komt staat naast de
// bus met een telefoon in de hand; alles wat niet bij die invoer hoort is
// weggelaten.

// Een eigen URL voor de functie is de bedoelde instelling; staat hij niet, dan
// valt hij terug op de Supabase-URL die de rest van de app ook gebruikt. Zo
// werkt de pagina ook als alleen de bestaande env-vars gezet zijn.
const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const ANON = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;
const API = (import.meta.env.VITE_BENU_COURIER_API as string | undefined)
  || (SUPABASE_URL ? `${SUPABASE_URL}/functions/v1/benu-courier-form` : '');

interface BenuPharmacyRow {
  id: string;
  pharmacy_id: string;
  pharmacy_name: string;
  planned_minutes: number | null;
  pda_minutes: number | null;
  extra_reason: string | null;
  status: string;
}

interface BenuEntry {
  shift_id: string;
  shift_date: string;              // 'YYYY-MM-DD'
  courier_name: string | null;
  submitted_at: string | null;
  token_expires_at: string;
  courier_note: string | null;
  pharmacies: BenuPharmacyRow[];
}

const WEEKDAYS = ['zondag', 'maandag', 'dinsdag', 'woensdag', 'donderdag', 'vrijdag', 'zaterdag'];

// 'YYYY-MM-DD' → 'vrijdag 25-09-2026'. Als losse getallen aan Date, want de
// stringvorm schuift in sommige browsers een dag op door de tijdzone.
function formatDate(iso: string): string {
  const [y, m, d] = iso.split('-').map(Number);
  const day = WEEKDAYS[new Date(y, m - 1, d).getDay()];
  return `${day} ${String(d).padStart(2, '0')}-${String(m).padStart(2, '0')}-${y}`;
}

// 'A', 'A en B', 'A, B en C'.
function joinNames(names: string[]): string {
  if (names.length === 0) return 'je apotheek';
  if (names.length === 1) return names[0];
  return `${names.slice(0, -1).join(', ')} en ${names[names.length - 1]}`;
}

export default function BenuCourierPage({ token }: { token: string }) {
  const [entry, setEntry] = useState<BenuEntry | null>(null);
  const [loading, setLoading] = useState(true);
  const [invalid, setInvalid] = useState(false);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState(false);

  // Invoer per pharmacy_id. Minuten blijven een string tot het versturen: een
  // leeg veld en een 0 zijn twee verschillende dingen, en dat onderscheid gaat
  // verloren zodra je er meteen een getal van maakt.
  const [minutes, setMinutes] = useState<Record<string, string>>({});
  const [reasons, setReasons] = useState<Record<string, string>>({});
  const [note, setNote] = useState('');

  const headers = {
    'Content-Type': 'application/json',
    'apikey': ANON ?? '',
    'Authorization': `Bearer ${ANON}`,
  };

  useEffect(() => {
    if (!token || !API || !ANON) { setInvalid(true); setLoading(false); return; }
    fetch(`${API}?t=${encodeURIComponent(token)}`, { headers })
      .then(async (res) => {
        const body = await res.json().catch(() => null);
        if (!res.ok || !body?.entry) { setInvalid(true); return; }
        setEntry(body.entry as BenuEntry);
      })
      .catch(() => setError('Laden mislukt. Probeer het later opnieuw.'))
      .finally(() => setLoading(false));
  }, [token]);

  const rows = entry?.pharmacies ?? [];

  // Per apotheek: hoeveel minuten meer dan gepland. Zonder begroting is er geen
  // "meer dan gepland" — dan blijft de reden dus ook onverplicht.
  const extraFor = useMemo(() => {
    const map: Record<string, number> = {};
    for (const r of rows) {
      const typed = Number(minutes[r.pharmacy_id]);
      if (r.planned_minutes === null || !Number.isInteger(typed)) { map[r.pharmacy_id] = 0; continue; }
      map[r.pharmacy_id] = Math.max(0, typed - r.planned_minutes);
    }
    return map;
  }, [rows, minutes]);

  const canSubmit = rows.length > 0 && rows.every((r) => {
    const raw = (minutes[r.pharmacy_id] ?? '').trim();
    const typed = Number(raw);
    if (raw === '' || !Number.isInteger(typed) || typed < 0) return false;
    if (extraFor[r.pharmacy_id] > 0 && !(reasons[r.pharmacy_id] ?? '').trim()) return false;
    return true;
  });

  async function submit() {
    setBusy(true);
    setError('');
    try {
      const res = await fetch(API, {
        method: 'POST',
        headers,
        body: JSON.stringify({
          token,
          entries: rows.map((r) => ({
            pharmacy_id: r.pharmacy_id,
            pda_minutes: Number((minutes[r.pharmacy_id] ?? '').trim()),
            extra_reason: (reasons[r.pharmacy_id] ?? '').trim() || null,
          })),
          note: note.trim() || null,
        }),
      });
      const body = await res.json().catch(() => null);
      if (!res.ok) {
        if (body?.error === 'link_ongeldig') { setInvalid(true); return; }
        setError(body?.error ?? 'Er ging iets mis.');
        return;
      }
      setDone(true);
    } catch {
      setError('Er ging iets mis. Probeer het later opnieuw.');
    } finally {
      setBusy(false);
    }
  }

  if (loading) return <Shell><p className="text-slate-500">Laden…</p></Shell>;

  if (invalid) {
    return (
      <Shell>
        <div className="flex items-start gap-2 text-slate-700">
          <AlertTriangle size={18} className="mt-0.5 shrink-0 text-amber-500" />
          <div>
            <p className="font-semibold text-slate-800">Deze link werkt niet meer</p>
            <p className="text-sm mt-1">
              Hij is verlopen of hoort niet bij een dienst. Bel of mail de planning als je je
              tijden nog wilt doorgeven.
            </p>
          </div>
        </div>
      </Shell>
    );
  }

  if (!entry) return <Shell><p className="text-red-600 text-sm">{error || 'Laden mislukt.'}</p></Shell>;

  const expired = new Date(entry.token_expires_at).getTime() < Date.now();
  const alreadySubmitted = entry.submitted_at !== null;

  // ── Bevestiging: net ingediend, of al eerder ─────────────────────────────
  if (done || alreadySubmitted) {
    return (
      <Shell>
        <div className="flex items-start gap-2 rounded-lg bg-green-50 border border-green-200 p-3 text-sm text-green-800">
          <Check size={16} className="mt-0.5 shrink-0" />
          <div>
            <p className="font-semibold">Bedankt! Je tijden zijn ontvangen.</p>
            <p className="mt-1">{formatDate(entry.shift_date)}</p>
          </div>
        </div>

        <ul className="mt-4 divide-y divide-slate-100 text-sm">
          {rows.map((r) => {
            // Na het indienen komen de minuten uit de database; is de pagina nog
            // niet herladen, dan staat de zojuist getypte waarde er.
            const shown = r.pda_minutes ?? Number((minutes[r.pharmacy_id] ?? '').trim());
            const extra = r.planned_minutes === null ? 0 : Math.max(0, (shown || 0) - r.planned_minutes);
            return (
              <li key={r.id} className="py-2">
                <span className="font-medium text-slate-800">{r.pharmacy_name}</span>
                {': '}
                {Number.isFinite(shown) ? `${shown} min` : '—'}
                {extra > 0 && (
                  <span className="text-amber-700"> ({extra} min meer dan gepland)</span>
                )}
              </li>
            );
          })}
        </ul>
      </Shell>
    );
  }

  if (expired) {
    return (
      <Shell>
        <div className="flex items-start gap-2 text-slate-700">
          <Clock size={18} className="mt-0.5 shrink-0 text-amber-500" />
          <div>
            <p className="font-semibold text-slate-800">De invultermijn is verstreken</p>
            <p className="text-sm mt-1">
              Je kon deze tijden tot de volgende ochtend 10:00 doorgeven. Bel of mail de planning,
              dan verwerken we ze met de hand.
            </p>
          </div>
        </div>
      </Shell>
    );
  }

  // ── Het formulier ────────────────────────────────────────────────────────
  return (
    <Shell>
      <h1 className="font-semibold text-slate-800">
        BENU tijdinvoer — {formatDate(entry.shift_date)}
      </h1>
      <p className="text-sm text-slate-600 mt-1">
        Vul de PDA-tijden in voor je dienst bij {joinNames(rows.map((r) => r.pharmacy_name))}
      </p>

      <div className="mt-4 space-y-4">
        {rows.map((r) => {
          const extra = extraFor[r.pharmacy_id] ?? 0;
          return (
            <div key={r.id} className="rounded-lg border border-slate-200 p-3">
              <p className="font-medium text-slate-800 text-sm">{r.pharmacy_name}</p>
              <p className="text-xs text-slate-500 mt-0.5">
                Gepland: {r.planned_minutes ?? '—'} min
              </p>

              <input
                type="number" min={0} step={1} inputMode="numeric"
                value={minutes[r.pharmacy_id] ?? ''}
                disabled={busy}
                placeholder="PDA-minuten"
                onChange={(e) => setMinutes((m) => ({ ...m, [r.pharmacy_id]: e.target.value }))}
                className="mt-2 w-full border border-slate-300 rounded-lg px-3 py-2 text-sm bg-white disabled:opacity-60"
              />

              {extra > 0 && (
                <div className="mt-2">
                  <p className="text-xs text-amber-700">
                    Dit is {extra} {extra === 1 ? 'minuut' : 'minuten'} meer dan gepland.
                  </p>
                  <label className="block mt-1.5">
                    <span className="block text-xs text-slate-700">Reden voor de extra tijd</span>
                    <textarea
                      rows={2} maxLength={500} disabled={busy}
                      value={reasons[r.pharmacy_id] ?? ''}
                      onChange={(e) => setReasons((m) => ({ ...m, [r.pharmacy_id]: e.target.value }))}
                      className="mt-1 w-full border border-slate-300 rounded-lg px-3 py-2 text-sm bg-white disabled:opacity-60"
                    />
                  </label>
                </div>
              )}
            </div>
          );
        })}
      </div>

      <label className="block mt-4">
        <span className="block text-sm text-slate-700">Overige opmerking (mag leeg blijven)</span>
        <textarea
          rows={2} maxLength={500} value={note} disabled={busy}
          onChange={(e) => setNote(e.target.value)}
          className="mt-1 w-full border border-slate-300 rounded-lg px-3 py-2 text-sm bg-white disabled:opacity-60"
        />
      </label>

      {error && <p className="text-sm text-red-600 mt-3">{error}</p>}

      <button
        type="button" onClick={submit} disabled={busy || !canSubmit}
        className="mt-4 w-full py-3 rounded-lg bg-green-600 hover:bg-green-700 disabled:opacity-60 text-white font-medium"
      >
        {busy ? 'Bezig…' : 'Indienen'}
      </button>

      {!canSubmit && (
        <p className="text-xs text-slate-400 mt-2">
          Vul bij elke apotheek een heel aantal minuten in, en een reden waar je langer bezig was.
        </p>
      )}
    </Shell>
  );
}

function Shell({ children }: { children: React.ReactNode }) {
  return (
    <div className="min-h-full bg-slate-100 py-6 px-4">
      <div className="mx-auto w-full max-w-md">
        <p className="text-green-700 font-semibold text-sm mb-3">Greenspeed</p>
        <div className="bg-white rounded-xl shadow-sm border border-slate-200 p-5">
          {children}
        </div>
      </div>
    </div>
  );
}
