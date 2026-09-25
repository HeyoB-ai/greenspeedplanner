import { useEffect, useState } from 'react';
import { AlertTriangle, Check, Info, X } from 'lucide-react';

// ── De BENU-reactiepagina voor de apotheek ────────────────────────────────
// Achter de link uit de mail die uitgaat zodra een koerier extra tijd meldt.
// Geen inlog: het token in de URL is het hele bewijs. De pagina praat
// uitsluitend met de Edge Function benu-pharmacy-form.
//
// Eén vraag, twee knoppen — zelfde opzet als de meerwerkpagina. Ook ná een
// antwoord blijft de pagina leesbaar: wie heeft goedgekeurd wil dat kunnen
// terugzien.

const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const ANON = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;
const API = (import.meta.env.VITE_BENU_PHARMACY_API as string | undefined)
  || (SUPABASE_URL ? `${SUPABASE_URL}/functions/v1/benu-pharmacy-form` : '');

type BenuStatus = 'pending' | 'no_extra' | 'submitted' | 'approved' | 'disputed' | 'auto_approved';

interface BenuPharmacyEntry {
  shift_date: string;              // 'YYYY-MM-DD'
  pharmacy_name: string;
  courier_name: string | null;
  planned_minutes: number | null;
  pda_minutes: number | null;
  extra_reason: string | null;
  status: BenuStatus;
  dispute_deadline: string | null;
  responded_at: string | null;
  pharmacy_note: string | null;
}

const WEEKDAYS = ['zondag', 'maandag', 'dinsdag', 'woensdag', 'donderdag', 'vrijdag', 'zaterdag'];

function formatDate(iso: string): string {
  const [y, m, d] = iso.split('-').map(Number);
  const day = WEEKDAYS[new Date(y, m - 1, d).getDay()];
  return `${day} ${String(d).padStart(2, '0')}-${String(m).padStart(2, '0')}-${y}`;
}

// ISO-timestamp → '27-09-2026 om 14:30' in Amsterdamse tijd.
function formatMoment(iso: string): string {
  const parts = new Intl.DateTimeFormat('nl-NL', {
    timeZone: 'Europe/Amsterdam',
    day: '2-digit', month: '2-digit', year: 'numeric',
    hour: '2-digit', minute: '2-digit', hour12: false,
  }).formatToParts(new Date(iso));
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? '';
  return `${get('day')}-${get('month')}-${get('year')} om ${get('hour')}:${get('minute')}`;
}

const STATUS_TEXT: Record<string, { title: string; body: string; tone: 'green' | 'amber' | 'slate' }> = {
  approved: {
    title: 'Akkoord gegeven',
    body: 'De extra tijd wordt doorbelast op de eerstvolgende factuur.',
    tone: 'green',
  },
  disputed: {
    title: 'Niet akkoord',
    body: 'We nemen contact met u op om dit door te nemen. De extra tijd staat zolang niet op de factuur.',
    tone: 'amber',
  },
  auto_approved: {
    title: 'Automatisch goedgekeurd',
    body: 'Er is niet binnen de termijn gereageerd, dus de extra tijd is doorbelast. Klopt er iets niet? Bel of mail ons.',
    tone: 'slate',
  },
  no_extra: {
    title: 'Geen extra tijd',
    body: 'De koerier is binnen de geplande tijd gebleven. Er valt niets te beoordelen.',
    tone: 'slate',
  },
  pending: {
    title: 'Nog niet ingediend',
    body: 'De koerier heeft zijn tijden voor deze dienst nog niet doorgegeven.',
    tone: 'slate',
  },
};

export default function BenuPharmacyPage({ token }: { token: string }) {
  const [entry, setEntry] = useState<BenuPharmacyEntry | null>(null);
  const [loading, setLoading] = useState(true);
  const [invalid, setInvalid] = useState(false);
  const [error, setError] = useState('');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  // Pas bij "niet akkoord" is een toelichting verplicht; hij staat er dus niet
  // meteen, anders leest het formulier als twee vragen in plaats van één.
  const [refusing, setRefusing] = useState(false);

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
        setEntry(body.entry as BenuPharmacyEntry);
      })
      .catch(() => setError('Laden mislukt. Probeer het later opnieuw.'))
      .finally(() => setLoading(false));
  }, [token]);

  async function respond(approve: boolean) {
    setBusy(true);
    setError('');
    try {
      const res = await fetch(API, {
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
      if (body?.entry) setEntry(body.entry as BenuPharmacyEntry);
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
              Hij is verlopen of hoort niet bij een melding. Bel of mail Greenspeed als u nog iets
              wilt doorgeven.
            </p>
          </div>
        </div>
      </Shell>
    );
  }

  if (!entry) return <Shell><p className="text-red-600 text-sm">{error || 'Laden mislukt.'}</p></Shell>;

  const planned = entry.planned_minutes;
  const pda = entry.pda_minutes ?? 0;
  const extra = planned === null ? pda : Math.max(0, pda - planned);
  const open = entry.status === 'submitted';
  const info = STATUS_TEXT[entry.status];

  return (
    <Shell>
      <h1 className="font-semibold text-slate-800">Extra tijd — {entry.pharmacy_name}</h1>
      <p className="text-sm text-slate-600 mt-1">
        Dienst van {formatDate(entry.shift_date)} — koerier: {entry.courier_name ?? 'onbekend'}
      </p>

      <dl className="mt-4 rounded-lg bg-slate-50 border border-slate-200 p-3 text-sm space-y-1">
        <div className="flex justify-between">
          <dt className="text-slate-500">Geplande tijd</dt>
          <dd className="text-slate-800">{planned ?? '—'} min</dd>
        </div>
        <div className="flex justify-between">
          <dt className="text-slate-500">PDA-tijd</dt>
          <dd className="text-slate-800">{entry.pda_minutes ?? '—'} min</dd>
        </div>
        <div className="flex justify-between font-medium">
          <dt className="text-slate-600">Extra</dt>
          <dd className="text-amber-700">{extra} min</dd>
        </div>
      </dl>

      {entry.extra_reason && (
        <div className="mt-3 rounded-lg border border-slate-200 p-3 text-sm">
          <p className="text-xs text-slate-500">Toelichting koerier</p>
          <p className="mt-0.5 text-slate-700">{entry.extra_reason}</p>
        </div>
      )}

      {/* ── Al beantwoord of niet te beantwoorden: lezen, niet beslissen ──── */}
      {!open && info && (
        <div className={`mt-4 flex items-start gap-2 rounded-lg border p-3 text-sm ${
          info.tone === 'green' ? 'bg-green-50 border-green-200 text-green-800'
          : info.tone === 'amber' ? 'bg-amber-50 border-amber-200 text-amber-800'
          : 'bg-slate-100 border-slate-200 text-slate-700'
        }`}>
          {info.tone === 'green' ? <Check size={16} className="mt-0.5 shrink-0" />
            : info.tone === 'amber' ? <X size={16} className="mt-0.5 shrink-0" />
            : <Info size={16} className="mt-0.5 shrink-0" />}
          <div>
            <p className="font-semibold">{info.title}</p>
            <p className="mt-1">{info.body}</p>
            {entry.responded_at && (
              <p className="mt-1 text-xs">Gereageerd op {formatMoment(entry.responded_at)}.</p>
            )}
            {entry.pharmacy_note && <p className="mt-1 italic">“{entry.pharmacy_note}”</p>}
          </div>
        </div>
      )}

      {/* ── Nog te beantwoorden ──────────────────────────────────────────── */}
      {open && (
        <>
          {refusing && (
            <label className="block mt-4">
              <span className="block text-sm text-slate-700">Toelichting</span>
              <textarea
                rows={2} maxLength={500} value={note} disabled={busy}
                onChange={(e) => setNote(e.target.value)}
                className="mt-1 w-full border border-slate-300 rounded-lg px-3 py-2 text-sm bg-white disabled:opacity-60"
              />
            </label>
          )}

          {error && <p className="text-sm text-red-600 mt-3">{error}</p>}

          <div className="mt-4 flex gap-2">
            <button
              type="button" onClick={() => respond(true)} disabled={busy || refusing}
              className="flex-1 py-3 rounded-lg bg-green-600 hover:bg-green-700 disabled:opacity-60 text-white font-medium"
            >
              {busy ? 'Bezig…' : 'Akkoord'}
            </button>
            <button
              type="button"
              onClick={() => (refusing ? respond(false) : setRefusing(true))}
              disabled={busy || (refusing && !note.trim())}
              className="flex-1 py-3 rounded-lg border border-slate-300 hover:border-slate-400 disabled:opacity-60 font-medium"
            >
              {refusing ? 'Versturen' : 'Niet akkoord'}
            </button>
          </div>

          {refusing && (
            <button
              type="button" onClick={() => { setRefusing(false); setNote(''); }} disabled={busy}
              className="mt-2 w-full text-xs text-slate-500 hover:text-slate-700"
            >
              Toch akkoord? Annuleer deze toelichting.
            </button>
          )}

          {entry.dispute_deadline && (
            <p className="text-xs text-slate-400 mt-3">
              Zonder reactie vóór {formatMoment(entry.dispute_deadline)} wordt de extra tijd
              automatisch goedgekeurd.
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
