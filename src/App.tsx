import { useEffect, useState } from 'react';
import { AlertTriangle, Building2, CalendarClock, Clock, FileText, Home, LogOut, Phone, Receipt, RefreshCw, Settings, Trash2, User, Users, Wallet } from 'lucide-react';
import { isConfigured } from './lib/supabase';
import { isPlanner, loadSessionUser, logout } from './lib/session';
import { SessionUser, Shift } from './types';
import Login from './components/Login';
import MenuButton from './components/MenuButton';
import WeekOverview from './planner/WeekOverview';
import ShiftForm from './planner/ShiftForm';
import PharmacySchedule from './planner/PharmacySchedule';
import CourierContacts from './planner/CourierContacts';
import CourierAddresses from './planner/CourierAddresses';
import Pharmacies from './planner/Pharmacies';
import Invoicing from './planner/Invoicing';
import Employees from './planner/Employees';
import ExtraWork from './planner/ExtraWork';
import Declarations from './planner/Declarations';
import { deleteShift } from './planner/plannerService';
import { getMaxHolidayDate, scheduleHorizonEndISO, topUpScheduleWindow } from './planner/scheduleService';
import { Attention, getAttention, NO_ATTENTION } from './planner/attentionService';
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
  const [showPharmacies, setShowPharmacies] = useState(false);
  const [showInvoicing, setShowInvoicing] = useState(false);
  const [showEmployees, setShowEmployees] = useState(false);
  const [showExtraWork, setShowExtraWork] = useState(false);
  const [showDeclarations, setShowDeclarations] = useState(false);
  const [maxHoliday, setMaxHoliday] = useState<string | null>(null);
  const [attention, setAttention] = useState<Attention>(NO_ATTENTION);
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

  // De telling achter de badge op Financieel. Meeliften op refreshSignal is
  // genoeg: dat gaat omhoog na elke mutatie en bij Vernieuwen, en de schermen
  // die de stand veranderen hogen het bij het sluiten op.
  //
  // Mislukt de aanroep, dan valt de badge stil in plaats van het scherm te
  // breken. Dat dekt ook de periode waarin migratie 033 nog niet gedraaid is.
  useEffect(() => {
    if (!isPlanner(user)) { setAttention(NO_ATTENTION); return; }
    getAttention().then(setAttention).catch(() => setAttention(NO_ATTENTION));
  }, [user, refreshSignal]);

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
      <header className="flex items-center justify-between gap-3 px-4 py-3 bg-white border-b border-slate-200">
        <h1 className="font-semibold text-green-700">Greenspeed Planner</h1>
        {/* Tien knoppen naast elkaar liepen de balk vol. Wat je tijdens het
            plannen gebruikt blijft los staan; de rest zit onder Beheer (zelden
            aangeraakt) en Financieel (de maandelijkse ronde: declaratie →
            meerwerk → factuur, in die volgorde). */}
        <div className="flex items-center gap-1 text-sm text-slate-600">
          <button
            onClick={() => topUpScheduleWindow().then((n) => { if (n > 0) setRefreshSignal((x) => x + 1); }).catch(() => {})}
            className="inline-flex items-center gap-1 rounded-lg px-2 py-1 hover:bg-slate-100 hover:text-slate-900"
            title="Roosterconcepten bijwerken t/m het venster-einde"
          >
            <CalendarClock size={15} /> Rooster bijwerken
          </button>
          <button
            onClick={() => setRefreshSignal((n) => n + 1)}
            className="inline-flex items-center gap-1 rounded-lg px-2 py-1 hover:bg-slate-100 hover:text-slate-900"
          >
            <RefreshCw size={15} /> Vernieuwen
          </button>

          <MenuButton
            label="Beheer"
            icon={<Settings size={15} />}
            items={[
              {
                key: 'employees', label: 'Medewerkers', icon: <Users size={15} />,
                title: 'Personeelsadministratie — los van wie er kan inloggen',
                onSelect: () => setShowEmployees(true),
              },
              {
                key: 'pharmacies', label: 'Apotheken', icon: <Building2 size={15} />,
                title: 'Plaatsnaam, tarieven, factuuradres en ketens',
                onSelect: () => setShowPharmacies(true),
              },
              {
                key: 'addresses', label: 'Afstanden', icon: <Home size={15} />,
                title: 'Standplaats en reisafstanden per koerier',
                onSelect: () => setShowAddresses(true),
              },
              {
                key: 'contacts', label: 'Nummers', icon: <Phone size={15} />,
                title: 'Mobiele nummers van koeriers beheren',
                onSelect: () => setShowContacts(true),
              },
            ]}
          />

          {/* De badge is de tegenprestatie voor het wegstoppen: zonder telling
              verdwijnt een ingediende declaratie of een nieuwe melding achter
              een klik. Geteld wordt alleen wat op de planner ligt te wachten. */}
          <MenuButton
            label="Financieel"
            icon={<Wallet size={15} />}
            badge={attention.total}
            badgeTitle={`${attention.declarations} declaratie(s) te beoordelen, ${attention.extraWork} meerwerkmelding(en) vrij te geven`}
            items={[
              {
                key: 'declarations', label: 'Declaraties', icon: <FileText size={15} />,
                title: 'Wat koeriers na afloop opgaven, naast wat het systeem berekende',
                badge: attention.declarations,
                onSelect: () => setShowDeclarations(true),
              },
              {
                key: 'extrawork', label: 'Meerwerk', icon: <Clock size={15} />,
                title: 'Uitgelopen diensten vrijgeven voor goedkeuring door de apotheek',
                badge: attention.extraWork,
                onSelect: () => setShowExtraWork(true),
              },
              {
                key: 'invoicing', label: 'Facturatie', icon: <Receipt size={15} />,
                title: 'Factuurregels per apotheek per periode',
                onSelect: () => setShowInvoicing(true),
              },
            ]}
          />

          <span className="mx-1 h-5 w-px bg-slate-200" aria-hidden="true" />

          <MenuButton
            label={user.name}
            icon={<User size={15} />}
            items={[
              {
                key: 'logout', label: 'Uitloggen', icon: <LogOut size={15} />,
                onSelect: () => { logout().then(() => setUser(null)).catch(() => setUser(null)); },
              },
            ]}
          />
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

      {showPharmacies && (
        <Pharmacies
          onClose={() => {
            setShowPharmacies(false);
            // De plaats bepaalt de groepen in het weekoverzicht, dus dat moet de
            // wijziging meteen zien.
            setRefreshSignal((n) => n + 1);
          }}
        />
      )}

      {showAddresses && <CourierAddresses onClose={() => setShowAddresses(false)} />}

      {/* Beoordelen haalt rijen uit de telling; het sluiten van het scherm
          moet de badge dus bijwerken. */}
      {showDeclarations && (
        <Declarations onClose={() => { setShowDeclarations(false); setRefreshSignal((n) => n + 1); }} />
      )}

      {showInvoicing && <Invoicing onClose={() => setShowInvoicing(false)} />}

      {showEmployees && <Employees onClose={() => setShowEmployees(false)} />}

      {showExtraWork && (
        <ExtraWork onClose={() => { setShowExtraWork(false); setRefreshSignal((n) => n + 1); }} />
      )}

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
