import { useEffect, useState } from 'react';
import { LogOut, RefreshCw, Trash2 } from 'lucide-react';
import { isConfigured } from './lib/supabase';
import { isPlanner, loadSessionUser, logout } from './lib/session';
import { SessionUser, Shift } from './types';
import Login from './components/Login';
import WeekOverview from './planner/WeekOverview';
import ShiftForm from './planner/ShiftForm';
import { deleteShift } from './planner/plannerService';
import { TYPE_STYLES } from './planner/constants';

// Eén formulier-doel voor zowel aanmaken als bewerken. Het openen van dit
// formulier (en de verwijderdialoog) gebeurt hier in App, zodat App het enige
// punt blijft dat het refreshSignal ophoogt na een geslaagde mutatie.
type FormTarget =
  | { mode: 'create'; pharmacyId: string; dateISO: string }
  | { mode: 'edit'; shift: Shift };

export default function App() {
  const [user, setUser] = useState<SessionUser | null>(null);
  const [checking, setChecking] = useState(true);
  const [formTarget, setFormTarget] = useState<FormTarget | null>(null);
  const [deletingShift, setDeletingShift] = useState<Shift | null>(null);
  const [deleteBusy, setDeleteBusy] = useState(false);
  const [deleteError, setDeleteError] = useState('');
  const [refreshSignal, setRefreshSignal] = useState(0);

  useEffect(() => {
    loadSessionUser().then(setUser).finally(() => setChecking(false));
  }, []);

  async function confirmDelete() {
    if (!deletingShift) return;
    setDeleteBusy(true);
    setDeleteError('');
    try {
      await deleteShift(deletingShift.id);
      setDeletingShift(null);
      setRefreshSignal((n) => n + 1);
    } catch (e: any) {
      setDeleteError(e?.message ?? 'Verwijderen mislukt.');
    } finally {
      setDeleteBusy(false);
    }
  }

  if (!isConfigured) {
    return (
      <div className="min-h-full flex items-center justify-center p-6">
        <div className="max-w-md text-center text-slate-600">
          <p className="font-semibold text-slate-800">Supabase niet geconfigureerd</p>
          <p className="text-sm mt-1">
            Zet <code>VITE_SUPABASE_URL</code> en <code>VITE_SUPABASE_ANON_KEY</code> in je
            omgeving (zie <code>.env.example</code>).
          </p>
        </div>
      </div>
    );
  }

  if (checking) {
    return <div className="min-h-full flex items-center justify-center text-slate-500">Laden…</div>;
  }

  if (!user) return <Login onLoggedIn={setUser} />;

  if (!isPlanner(user)) {
    return (
      <div className="min-h-full flex items-center justify-center p-6">
        <div className="max-w-md text-center">
          <p className="font-semibold text-slate-800">Geen toegang</p>
          <p className="text-sm text-slate-600 mt-1">
            Het plannerscherm is alleen voor planners (superuser, supervisor, admin).
          </p>
          <button
            onClick={async () => { await logout(); setUser(null); }}
            className="mt-4 text-sm text-slate-600 underline"
          >
            Uitloggen
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-full">
      <header className="flex items-center justify-between px-4 py-3 bg-white border-b border-slate-200">
        <h1 className="font-semibold text-green-700">Greenspeed Planner</h1>
        <div className="flex items-center gap-3 text-sm text-slate-600">
          <span>{user.name}</span>
          <button
            onClick={() => setRefreshSignal((n) => n + 1)}
            className="inline-flex items-center gap-1 hover:text-slate-900"
          >
            <RefreshCw size={15} /> Vernieuwen
          </button>
          <button
            onClick={async () => { await logout(); setUser(null); }}
            className="inline-flex items-center gap-1 hover:text-slate-900"
          >
            <LogOut size={15} /> Uitloggen
          </button>
        </div>
      </header>

      <WeekOverview
        onCreate={(pharmacyId, dateISO) => setFormTarget({ mode: 'create', pharmacyId, dateISO })}
        onEdit={(shift) => setFormTarget({ mode: 'edit', shift })}
        onDelete={(shift) => { setDeleteError(''); setDeletingShift(shift); }}
        onChanged={() => setRefreshSignal((n) => n + 1)}
        refreshSignal={refreshSignal}
      />

      {formTarget && (
        <ShiftForm
          shift={formTarget.mode === 'edit' ? formTarget.shift : undefined}
          initialPharmacyId={formTarget.mode === 'create' ? formTarget.pharmacyId : undefined}
          initialDateISO={formTarget.mode === 'create' ? formTarget.dateISO : undefined}
          onClose={() => setFormTarget(null)}
          onSaved={() => {
            setFormTarget(null);
            setRefreshSignal((n) => n + 1);
          }}
        />
      )}

      {deletingShift && (
        <div
          className="fixed inset-0 bg-black/40 flex items-center justify-center p-4"
          onClick={() => !deleteBusy && setDeletingShift(null)}
        >
          <div className="bg-white rounded-xl shadow-lg w-full max-w-sm p-5 space-y-4" onClick={(e) => e.stopPropagation()}>
            <div className="flex items-center gap-2 text-red-600">
              <Trash2 size={18} />
              <h2 className="font-semibold">Dienst verwijderen?</h2>
            </div>
            <p className="text-sm text-slate-600">Deze actie kan niet ongedaan gemaakt worden.</p>
            <dl className="text-sm bg-slate-50 rounded-lg p-3 space-y-1">
              <div className="flex justify-between gap-4">
                <dt className="text-slate-500">Type</dt>
                <dd className="font-medium">{TYPE_STYLES[deletingShift.shiftType].label}</dd>
              </div>
              <div className="flex justify-between gap-4">
                <dt className="text-slate-500">Datum</dt>
                <dd className="font-medium">{deletingShift.shiftDate}</dd>
              </div>
              <div className="flex justify-between gap-4">
                <dt className="text-slate-500">Tijd</dt>
                <dd className="font-medium tabular-nums">
                  {deletingShift.budgetedEndTime
                    ? `${deletingShift.startTime}–${deletingShift.budgetedEndTime}`
                    : deletingShift.startTime}
                </dd>
              </div>
              <div className="flex justify-between gap-4">
                <dt className="text-slate-500">Koerier</dt>
                <dd className="font-medium">
                  {deletingShift.courierId ? (deletingShift.courierName ?? 'Koerier') : 'Open'}
                </dd>
              </div>
            </dl>

            {deleteError && <p className="text-sm text-red-600">{deleteError}</p>}

            <div className="flex justify-end gap-2">
              <button
                type="button" disabled={deleteBusy}
                onClick={() => setDeletingShift(null)}
                className="px-4 py-2 text-sm text-slate-600 hover:text-slate-900 disabled:opacity-60"
              >
                Annuleren
              </button>
              <button
                type="button" disabled={deleteBusy}
                onClick={confirmDelete}
                className="px-4 py-2 text-sm bg-red-600 hover:bg-red-700 disabled:opacity-60 text-white rounded-lg font-medium"
              >
                {deleteBusy ? 'Verwijderen…' : 'Verwijderen'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
