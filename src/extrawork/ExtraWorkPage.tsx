import { useEffect, useState } from 'react';
import { AlertTriangle, Check, Clock, Info, X } from 'lucide-react';

// ── De pagina voor de apotheek ────────────────────────────────────────────
// Achter de link uit de meerwerkmail. Geen inlog: het token in de URL is het
// hele bewijs, net als bij de nadeclaratie van de koerier. De pagina praat
// uitsluitend met de Edge Function extra-work; extra_work heeft geen enkele
// RLS-policy en geen rechten voor anon.
//
// Eén vraag, twee knoppen. Wie hier komt heeft een mail geopend tussen het werk
// door; alles wat niet bij die ene vraag hoort is weggelaten.

const URL_BASE = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const ANON = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

interface ExtraWorkView {
  extra_work_id: string;
  status: 'new' | 'released' | 'approved' | 'disputed' | 'expired';
  pharmacy_name: string;
  shift_date: string;
  planned_start: string | null;
  planned_end: string | null;
  extra_minutes: number;
  note: string | null;
  respond_by: string | null;
  responded_at: string | null;
  response_note: string | null;
}

const WEEKDAYS = ['zondag', 'maandag', 'dinsdag', 'woensdag', 'donderdag', 'vrijdag', 'zaterdag'];

// 'YYYY-MM-DD' → 'donderdag 30-07-2026'. Als losse getallen aan Date, want de
// stringvorm schuift in sommige browsers een dag op door de tijdzone.
function formatDate(iso: string): string {
  const [y, m, d] = iso.split('-').map(Number);
  const day = WEEKDAYS[new Date(y, m - 1, d).getDay()];
  return `${day} ${String(d).padStart(2, '0')}-${String(m).padStart(2, '0')}-${y}`;
}

function minutesText(minutes: number): string {
  const total = Math.round(Number(minutes));
  const h = Math.floor(total / 60);
  const m = total % 60;
  if (h === 0) return `${m} minuten`;
  return m === 0 ? `${h} uur` : `${h} uur en ${m} minuten`;
}

export default function ExtraWorkPage({ token }: { token: string }) {
  const [view, setView] = useState<ExtraWorkView | null>(null);
  const [loading, setLoading] = useState(true);
  const [invalid, setInvalid] = useState(false);
  const [error, setError] = useState('');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);

  const endpoint = `${URL_BASE}/functions/v1/extra-work`;
  const headers = {
    'Content-Type': 'application/json',
    'apikey': ANON ?? '',
    'Authorization': `Bearer ${ANON}`,
  };

  useEffect(() => {
    if (!token || !URL_BASE || !ANON) { setInvalid(true); setLoading(false); return; }
    fetch(`${endpoint}?t=${encodeURIComponent(token)}`, { headers })
      .then(async (res) => {
        const body = await res.json().catch(() => null);
        if (!res.ok || !body?.extra_work) { setInvalid(true); return; }
        setView(body.extra_work as ExtraWorkView);
      })
      .catch(() => setError('Laden mislukt. Probeer het later opnieuw.'))
      .finally(() => setLoading(false));
  }, [token]);

  async function respond(approve: boolean) {
    setBusy(true);
    setError('');
    try {
      const res = await fetch(endpoint, {
        method: 'POST',
        headers,
        body: JSON.stringify({ token, approve, note: note.trim() || null }),
      });
      const body = await res.json().catch(() => null);
      if (!res.ok) {
        if (body?.error === 'link_ongeldig') { setInvalid(true); return; }
        setError(body?.error ?? 'Er ging iets mis.');
        return;
      }
      if (body?.extra_work) setView(body.extra_work as ExtraWorkView);
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
              Hij is verlopen of hoort niet bij een melding. Bel of mail Greenspeed als je nog iets
              wilt doorgeven.
            </p>
          </div>
        </div>
      </Shell>
    );
  }

  if (!view) return <Shell><p className="text-red-600 text-sm">{error || 'Laden mislukt.'}</p></Shell>;

  const answered = view.status === 'approved' || view.status === 'disputed';
  const expired = view.status === 'expired';

  return (
    <Shell>
      <h1 className="font-semibold text-slate-800">Extra tijd op een dienst</h1>
      <p className="text-sm text-slate-600 mt-1">{view.pharmacy_name}</p>

      <dl className="mt-4 rounded-lg bg-slate-50 border border-slate-200 p-3 text-sm space-y-1.5">
        <div className="flex items-start gap-2">
          <Clock size={15} className="mt-0.5 shrink-0 text-slate-400" />
          <dd>
            {formatDate(view.shift_date)}
            {view.planned_start && view.planned_end && (
              <span className="text-slate-500"> · gepland {view.planned_start}–{view.planned_end}</span>
            )}
          </dd>
        </div>
        <div className="flex items-start gap-2">
          <span className="w-[15px]" />
          <dd className="font-medium text-amber-700">
            {minutesText(view.extra_minutes)} langer dan gepland
          </dd>
        </div>
      </dl>

      {view.note && (
        <div className="mt-3 rounded-lg border border-slate-200 p-3 text-sm">
          <p className="text-xs text-slate-500">Toelichting</p>
          <p className="mt-0.5 text-slate-700">{view.note}</p>
        </div>
      )}

      {/* ── Al beantwoord: lezen, niet opnieuw beslissen ─────────────────── */}
      {answered && (
        <div className={`mt-4 flex items-start gap-2 rounded-lg border p-3 text-sm ${
          view.status === 'approved'
            ? 'bg-green-50 border-green-200 text-green-800'
            : 'bg-amber-50 border-amber-200 text-amber-800'
        }`}>
          {view.status === 'approved'
            ? <Check size={16} className="mt-0.5 shrink-0" />
            : <X size={16} className="mt-0.5 shrink-0" />}
          <div>
            <p className="font-semibold">
              {view.status === 'approved' ? 'Akkoord gegeven' : 'Niet akkoord'}
            </p>
            <p className="mt-1">
              {view.status === 'approved'
                ? 'De extra tijd wordt doorbelast op de eerstvolgende factuur.'
                : 'We nemen contact met je op om dit door te nemen. De extra tijd staat zolang niet op de factuur.'}
            </p>
            {view.response_note && <p className="mt-1 italic">“{view.response_note}”</p>}
          </div>
        </div>
      )}

      {expired && (
        <div className="mt-4 flex items-start gap-2 rounded-lg bg-slate-100 border border-slate-200 p-3 text-sm text-slate-700">
          <Info size={16} className="mt-0.5 shrink-0" />
          <div>
            <p className="font-semibold">De reactietermijn is verstreken</p>
            <p className="mt-1">
              De extra tijd is doorbelast. Klopt er iets niet? Bel of mail ons, dan kijken we er
              samen naar.
            </p>
          </div>
        </div>
      )}

      {/* ── Nog te beantwoorden ─────────────────────────────────────────── */}
      {!answered && !expired && (
        <>
          <label className="block mt-4">
            <span className="block text-sm text-slate-700">Opmerking (mag leeg blijven)</span>
            <textarea
              rows={2} value={note} disabled={busy}
              onChange={(e) => setNote(e.target.value)}
              className="mt-1 w-full border border-slate-300 rounded-lg px-3 py-2 text-sm bg-white disabled:opacity-60"
            />
          </label>

          {error && <p className="text-sm text-red-600 mt-3">{error}</p>}

          <div className="mt-4 flex gap-2">
            <button
              type="button" onClick={() => respond(true)} disabled={busy}
              className="flex-1 py-3 rounded-lg bg-green-600 hover:bg-green-700 disabled:opacity-60 text-white font-medium"
            >
              {busy ? 'Bezig…' : 'Akkoord'}
            </button>
            <button
              type="button" onClick={() => respond(false)} disabled={busy}
              className="flex-1 py-3 rounded-lg border border-slate-300 hover:border-slate-400 disabled:opacity-60 font-medium"
            >
              Niet akkoord
            </button>
          </div>

          {view.respond_by && (
            <p className="text-xs text-slate-400 mt-3">
              Zonder reactie belasten we de extra tijd door. Je hebt nog tot{' '}
              {formatDate(view.respond_by.slice(0, 10))}.
            </p>
          )}
        </>
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
