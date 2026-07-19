import { useEffect, useState } from 'react';
import { LogOut, RefreshCw } from 'lucide-react';
import { isConfigured } from './lib/supabase';
import { isPlanner, loadSessionUser, logout } from './lib/session';
import { SessionUser } from './types';
import Login from './components/Login';
import WeekOverview from './planner/WeekOverview';

interface CreateTarget { pharmacyId: string; dateISO: string; }

export default function App() {
  const [user, setUser] = useState<SessionUser | null>(null);
  const [checking, setChecking] = useState(true);
  const [createTarget, setCreateTarget] = useState<CreateTarget | null>(null);
  const [refreshSignal, setRefreshSignal] = useState(0);

  useEffect(() => {
    loadSessionUser().then(setUser).finally(() => setChecking(false));
  }, []);

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
        onCreate={(pharmacyId, dateISO) => setCreateTarget({ pharmacyId, dateISO })}
        refreshSignal={refreshSignal}
      />

      {/* Stap C vervangt deze placeholder door het echte aanmaakformulier. */}
      {createTarget && (
        <div className="fixed inset-0 bg-black/30 flex items-center justify-center p-4" onClick={() => setCreateTarget(null)}>
          <div className="bg-white rounded-xl p-6 max-w-sm text-sm" onClick={(e) => e.stopPropagation()}>
            <p className="font-semibold mb-1">Dienst aanmaken</p>
            <p className="text-slate-600">
              Apotheek <code>{createTarget.pharmacyId}</code> op {createTarget.dateISO}.
              Het aanmaakformulier volgt in stap C.
            </p>
            <button onClick={() => setCreateTarget(null)} className="mt-4 text-slate-600 underline">Sluiten</button>
          </div>
        </div>
      )}
    </div>
  );
}
