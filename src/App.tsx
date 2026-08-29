import { useEffect, useState } from 'react';
import { AlertTriangle, CalendarClock, FileText, Home, LogOut, Phone, RefreshCw, Trash2 } from 'lucide-react';
import { isConfigured } from './lib/supabase';
import { isPlanner, loadSessionUser, logout } from './lib/session';
import { SessionUser, Shift } from './types';
import Login from './components/Login';
import WeekOverview from './planner/WeekOverview';
import ShiftForm from './planner/ShiftForm';
import PharmacySchedule from './planner/PharmacySchedule';
import CourierContacts from './planner/CourierContacts';
import CourierAddresses from './planner/CourierAddresses';
import Declarations from './planner/Declarations';
import { deleteShift } from './planner/plannerService';
import { getMaxHolidayDate, scheduleHorizonEndISO, topUpScheduleWindow } from './planner/scheduleService';
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
  const [scheduleTarget, setScheduleTarget] = useState<{ id: string; name: string } | null>(null);
  const [showContacts, setShowContacts] = useState(false);
  const [showAddresses, setShowAddresses] = useState(false);
  const [showDeclarations, setShowDeclarations] = useState(false);
  const [maxHoliday, setMaxHoliday] = useState<string | null>(null);
  const [refreshSignal, setRefreshSignal] = useState(0);

  useEffect(() => {
    loadSessionUser().then(setUser).finally(() => setChecking(false));
  }, []);

  // Bij app-open: het roostervenster bijvullen (idempotent; marker staat in de DB).
  useEffect(() => {
    if (!isPlanner(user)) return;
    topUpScheduleWindow()
      .then((created) => { if (created > 0) setRefreshSignal((n) => n + 1); })
      .catch(() => { /* stil: generatie is niet kritisch voor het laden */ });
    getMaxHolidayDate().then(setMaxHoliday).catch(() => {});
  }, [user]);

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
            onClick={() => topUpScheduleWindow().then((n) => { if (n > 0) setRefreshSignal((x) => x + 1); }).catch(() => {})}
            className="inline-flex items-center gap-1 hover:text-slate-900"
            title="Roosterconcepten bijwerken t/m het venster-einde"
          >
            <CalendarClock size={15} /> Rooster bijwerken
          </button>
          <button
            onClick={() => setShowContacts(true)}
            className="inline-flex items-center gap-1 hover:text-slate-900"
            title="Mobiele nummers van koeriers beheren"
          >
            <Phone size={15} /> Nummers
          </button>
          <button
            onClick={() => setShowAddresses(true)}
            className="inline-flex items-center gap-1 hover:text-slate-900"
            title="Standplaats en reisafstanden per koerier"
          >
            <Home size={15} /> Afstanden
          </button>
          <button
            onClick={() => setShowDeclarations(true)}
            className="inline-flex items-center gap-1 hover:text-slate-900"
            title="Wat koeriers na afloop opgaven, naast wat het systeem berekende"
          >
            <FileText size={15} /> Declaraties
          </button>
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

      {/* De generator slaat alleen feestdagen over die in `holidays` staan. Reikt het
          roostervenster voorbij de laatst bekende feestdag, dan plant hij daarna
          stilzwijgend op feestdagen door — vandaar deze waarschuwing. Datums bewust in
          ISO: dat is precies de notatie die de planner in `holidays` moet invullen. */}
      {maxHoliday && scheduleHorizonEndISO() > maxHoliday && (
        <div className="bg-amber-50 border-b border-amber-200 text-amber-800 text-sm px-4 py-2 flex items-start gap-2">
          <AlertTriangle size={15} className="mt-0.5 shrink-0" />
          <span>
            Het roostervenster loopt t/m <strong>{scheduleHorizonEndISO()}</strong>, voorbij de laatst bekende
            feestdag (<strong>{maxHoliday}</strong>). Feestdagen ná die datum worden als werkdag ingepland —
            vul de <code>holidays</code>-tabel aan.
          </span>
        </div>
      )}

      <WeekOverview
        onCreate={(pharmacyId, dateISO) => setFormTarget({ mode: 'create', pharmacyId, dateISO })}
        onEdit={(shift) => setFormTarget({ mode: 'edit', shift })}
        onDelete={(shift) => { setDeleteError(''); setDeletingShift(shift); }}
        onOpenSchedule={(pharmacy) => setScheduleTarget(pharmacy)}
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
          className="fixed inset-0 z-50 bg-black/40 flex items-center justify-center p-4"
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

      {showContacts && <CourierContacts onClose={() => setShowContacts(false)} />}

      {showAddresses && <CourierAddresses onClose={() => setShowAddresses(false)} />}

      {showDeclarations && <Declarations onClose={() => setShowDeclarations(false)} />}

      {scheduleTarget && (
        <PharmacySchedule
          pharmacyId={scheduleTarget.id}
          pharmacyName={scheduleTarget.name}
          onClose={() => setScheduleTarget(null)}
          onChanged={() => setRefreshSignal((n) => n + 1)}
        />
      )}
    </div>
  );
}
