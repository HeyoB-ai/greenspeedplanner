import { useEffect, useState } from 'react';
import { AlertTriangle, Check, Clock, Info, MapPin } from 'lucide-react';
import {
  DeclarationClosedError, DeclarationView, LinkInvalidError, durationText, formatDate,
  joinNames, loadDeclaration, submitDeclaration,
} from './declarationApi';

interface Props {
  token: string;
}

// De pagina achter de link uit de nabericht-mail. Geen inlog, geen menu, geen
// andere diensten — één dienst, twee vragen. Alles wat er niet toe doet is
// weggelaten: wie hier komt staat waarschijnlijk op straat met zijn telefoon.
export default function DeclarationPage({ token }: Props) {
  const [view, setView] = useState<DeclarationView | null>(null);
  const [expectedHours, setExpectedHours] = useState<number | null>(null);
  const [loading, setLoading] = useState(true);
  const [invalid, setInvalid] = useState(false);
  // Gezet zodra de server zegt dat er niets meer op te slaan valt: verlopen, in
  // behandeling, of goedgekeurd. De tekst komt van de server mee.
  const [closed, setClosed] = useState('');
  const [error, setError] = useState('');

  const [start, setStart] = useState('');
  const [end, setEnd] = useState('');
  const [claims, setClaims] = useState<boolean | null>(null);
  const [km, setKm] = useState('');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const [saved, setSaved] = useState(false);

  useEffect(() => {
    if (!token) { setInvalid(true); setLoading(false); return; }
    loadDeclaration(token)
      .then(({ declaration: d, expectedWithinHours }) => {
        setView(d);
        setExpectedHours(expectedWithinHours);
        // Al ingevuld? Dan staat het er weer in, zodat corrigeren kan zolang de
        // planner er niet naar gekeken heeft.
        setStart(d.actual_start ?? '');
        setEnd(d.actual_end ?? '');
        setClaims(d.claims_travel);
        setKm(d.own_car_km != null ? String(d.own_car_km) : '');
        setNote(d.courier_note ?? '');
        setSaved(d.status === 'submitted');
      })
      .catch((e) => {
        if (e instanceof LinkInvalidError) setInvalid(true);
        else setError(e?.message ?? 'Laden mislukt.');
      })
      .finally(() => setLoading(false));
  }, [token]);

  async function save() {
    if (!view) return;
    setError('');

    if (!start || !end) { setError('Vul allebei de tijden in.'); return; }
    if (claims === null) { setError('Geef aan of je reiskosten declareert.'); return; }

    const wantsKm = claims && view.own_car;
    const kmValue = wantsKm ? Number(km.replace(',', '.')) : null;
    if (wantsKm && (!Number.isFinite(kmValue as number) || (kmValue as number) <= 0)) {
      setError('Vul het aantal gereden kilometers in.');
      return;
    }

    setBusy(true);
    try {
      const updated = await submitDeclaration(token, {
        actualStart: start,
        actualEnd: end,
        claimsTravel: claims,
        ownCarKm: kmValue,
        note: note.trim() || null,
      });
      if (updated) setView(updated);
      setSaved(true);
    } catch (e: any) {
      if (e instanceof LinkInvalidError) setInvalid(true);
      else if (e instanceof DeclarationClosedError) setClosed(e.message);
      else setError(e?.message ?? 'Opslaan mislukt.');
    } finally {
      setBusy(false);
    }
  }

  // ── Schermen die geen formulier zijn ───────────────────────────────────
  if (loading) {
    return <Shell><p className="text-slate-500">Laden…</p></Shell>;
  }

  if (invalid) {
    return (
      <Shell>
        <div className="flex items-start gap-2 text-slate-700">
          <AlertTriangle size={18} className="mt-0.5 shrink-0 text-amber-500" />
          <div>
            <p className="font-semibold text-slate-800">Deze link werkt niet meer</p>
            <p className="text-sm mt-1">
              Hij is verlopen, al afgehandeld, of hoort niet bij een dienst. Bel of mail de planning
              als je nog iets wilt doorgeven.
            </p>
          </div>
        </div>
      </Shell>
    );
  }

  // Er valt niets meer op te slaan. Dan is een rode regel onder een knop die het
  // toch niet doet misleidend: het formulier gaat dicht en de reden staat er.
  if (closed) {
    return (
      <Shell>
        <div className="flex items-start gap-2 text-slate-700">
          <Info size={18} className="mt-0.5 shrink-0 text-blue-500" />
          <div>
            <p className="font-semibold text-slate-800">Dit staat vast</p>
            <p className="text-sm mt-1">{closed}</p>
            {view && (
              <p className="text-xs text-slate-500 mt-2">
                Het gaat om je dienst van {formatDate(view.shift_date)} bij {joinNames(view.pharmacies)}.
              </p>
            )}
          </div>
        </div>
      </Shell>
    );
  }

  if (!view) {
    return <Shell><p className="text-red-600 text-sm">{error || 'Laden mislukt.'}</p></Shell>;
  }

  const duration = durationText(start, end);
  const wantsKm = claims === true && view.own_car;

  return (
    <Shell>
      <h1 className="font-semibold text-slate-800">Hoi {view.courier_name.split(' ')[0]},</h1>
      <p className="text-sm text-slate-600 mt-1">
        Je dienst zit erop. Twee vragen, dan is het klaar.
      </p>
      {/* Nadrukkelijk een verwachting en geen deadline. De tweede zin hoort
          erbij: wie denkt dat hij te laat is, vult helemaal niets meer in — en
          dan zijn we de opgave kwijt in plaats van dat hij laat is. Het getal
          komt uit de instelling, niet uit deze pagina. */}
      {expectedHours && (
        <p className="text-xs text-slate-500 mt-1">
          Fijn als je dit binnen {expectedHours} uur na je dienst doorgeeft. Later invullen kan ook,
          deze link blijft gewoon werken.
        </p>
      )}

      {/* Ter herkenning: welke dienst dit is. Alleen deze dienst, en niets over
          andere mensen. */}
      <dl className="mt-4 rounded-lg bg-slate-50 border border-slate-200 p-3 text-sm space-y-1.5">
        <div className="flex items-start gap-2">
          <Clock size={15} className="mt-0.5 shrink-0 text-slate-400" />
          <dd>
            {formatDate(view.shift_date)}
            <span className="text-slate-500">
              {' · gepland '}
              {view.budgeted_end_time ? `${view.start_time}–${view.budgeted_end_time}` : `vanaf ${view.start_time}`}
            </span>
          </dd>
        </div>
        <div className="flex items-start gap-2">
          <MapPin size={15} className="mt-0.5 shrink-0 text-slate-400" />
          <dd>{joinNames(view.pharmacies)}</dd>
        </div>
      </dl>

      {saved && (
        <div className="mt-4 flex items-start gap-2 rounded-lg bg-green-50 border border-green-200 text-green-800 text-sm p-3">
          <Check size={15} className="mt-0.5 shrink-0" />
          <span>
            Doorgegeven, bedankt. Je kunt het hieronder nog aanpassen zolang de planning het
            niet heeft nagekeken.
          </span>
        </div>
      )}

      {/* ── Vraag 1: de werkelijke duur ─────────────────────────────────── */}
      <section className="mt-5">
        <h2 className="text-sm font-semibold text-slate-800">Hoe lang duurde de dienst werkelijk?</h2>
        <div className="mt-2 flex items-center gap-3">
          <label className="flex-1">
            <span className="block text-xs text-slate-500 mb-1">Begonnen om</span>
            <input
              type="time" value={start} disabled={busy}
              onChange={(e) => setStart(e.target.value)}
              className="w-full border border-slate-300 rounded-lg px-3 py-2 text-base tabular-nums bg-white disabled:opacity-60"
            />
          </label>
          <label className="flex-1">
            <span className="block text-xs text-slate-500 mb-1">Klaar om</span>
            <input
              type="time" value={end} disabled={busy}
              onChange={(e) => setEnd(e.target.value)}
              className="w-full border border-slate-300 rounded-lg px-3 py-2 text-base tabular-nums bg-white disabled:opacity-60"
            />
          </label>
        </div>
        {duration && (
          <p className="text-xs text-slate-500 mt-1.5">Dat is {duration}.</p>
        )}
      </section>

      {/* ── Vraag 2: reiskosten ─────────────────────────────────────────── */}
      <section className="mt-5">
        <h2 className="text-sm font-semibold text-slate-800">Declareer je reiskosten voor deze dienst?</h2>
        <div className="mt-2 flex gap-2">
          {[
            { value: true, label: 'Ja' },
            { value: false, label: 'Nee' },
          ].map((opt) => (
            <button
              key={String(opt.value)} type="button" disabled={busy}
              onClick={() => setClaims(opt.value)}
              className={`flex-1 py-2.5 rounded-lg border text-sm font-medium disabled:opacity-60 ${
                claims === opt.value
                  ? 'bg-green-600 border-green-600 text-white'
                  : 'bg-white border-slate-300 text-slate-700 hover:border-slate-400'
              }`}
            >
              {opt.label}
            </button>
          ))}
        </div>

        {wantsKm && (
          <label className="block mt-3">
            {/* Deze formulering staat woordelijk ook in de mail. Zonder die
                definitie telt de een de bezorgroute mee en de ander niet, en zijn
                de opgaves achteraf niet met elkaar te vergelijken. */}
            <span className="block text-sm text-slate-700">
              Totaal gereden kilometers, vanaf vertrek thuis tot terugkomst thuis
            </span>
            <input
              type="text" inputMode="decimal" value={km} disabled={busy}
              placeholder="bv. 34,5"
              onChange={(e) => setKm(e.target.value)}
              className="mt-1 w-40 border border-slate-300 rounded-lg px-3 py-2 text-base tabular-nums bg-white disabled:opacity-60"
            />
            <span className="block text-xs text-slate-500 mt-1">
              Inclusief de bezorgroute zelf, dus je hele rit van deur tot deur.
            </span>
          </label>
        )}

        {claims === true && !view.own_car && (
          <p className="text-xs text-slate-500 mt-2">
            Je reed deze dienst niet op eigen kosten, dus je hoeft geen kilometers op te geven —
            de planning rekent het uit.
          </p>
        )}
      </section>

      {/* ── Ruimte voor het geval dat niet in een veld past ──────────────── */}
      <section className="mt-5">
        <label className="block">
          <span className="block text-sm text-slate-700">Iets bijzonders? (mag leeg blijven)</span>
          <textarea
            value={note} rows={2} disabled={busy}
            onChange={(e) => setNote(e.target.value)}
            placeholder="Bijvoorbeeld: langer doorgewerkt, of onderweg opgehouden."
            className="mt-1 w-full border border-slate-300 rounded-lg px-3 py-2 text-sm bg-white disabled:opacity-60"
          />
        </label>
      </section>

      {error && <p className="text-sm text-red-600 mt-3">{error}</p>}

      <button
        type="button" onClick={save} disabled={busy}
        className="mt-5 w-full py-3 rounded-lg bg-green-600 hover:bg-green-700 disabled:opacity-60 text-white font-medium"
      >
        {busy ? 'Bezig…' : saved ? 'Aanpassing doorgeven' : 'Doorgeven'}
      </button>

      <p className="text-xs text-slate-400 mt-4">
        Deze link hoort bij deze ene dienst. Deel hem niet.
      </p>
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
