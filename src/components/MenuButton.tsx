import { KeyboardEvent, FocusEvent, ReactNode, useEffect, useRef, useState } from 'react';
import { ChevronDown } from 'lucide-react';

// ── Uitklapmenu voor de menubalk ──────────────────────────────────────────
// Tien knoppen naast elkaar pasten niet meer. Ze zitten nu onder Beheer en
// Financieel — met als prijs dat wat eronder ligt niet meer zichtbaar is. Voor
// zeldzaam beheer is dat prima; voor werk dat binnenkomt niet, en daarvoor is
// de badge.
//
// TOETSENBORD
//   Tab      loopt door de items; ze zijn gewone knoppen en blijven dat, dus
//            er is geen roving tabindex die Tab uit het menu zou gooien.
//   Enter    opent en kiest (native gedrag van <button>).
//   Escape   sluit en zet de focus terug op de menuknop — anders staat de
//            focus na het sluiten nergens en begint tabben weer vooraan.
//   Pijltjes lopen ook door de items, rondlopend. Niet gevraagd, wel wat een
//            menu hoort te doen.
//
// Focus die het menu verlaat sluit het (onBlur op de omhullende div, met
// relatedTarget: bij een sprong naar het volgende item blijft het dus open).

export type MenuItem = {
  key: string;
  label: string;
  icon: ReactNode;
  title?: string;
  // Aantal onderdelen dat op de planner wacht. Staat ook op de menuknop zelf
  // als totaal; hier zodat na het uitklappen meteen zichtbaar is waar het zit.
  badge?: number;
  onSelect: () => void;
};

function Badge({ count, what }: { count: number; what: string }) {
  return (
    <span
      className="inline-flex min-w-[1.25rem] items-center justify-center rounded-full bg-amber-500 px-1.5 py-0.5 text-[11px] font-semibold leading-none text-white"
      title={what}
      aria-label={what}
    >
      {count > 99 ? '99+' : count}
    </span>
  );
}

export default function MenuButton({
  label, icon, items, badge, badgeTitle,
}: {
  label: string;
  icon: ReactNode;
  items: MenuItem[];
  badge?: number;
  badgeTitle?: string;
}) {
  const [open, setOpen] = useState(false);
  const wrapRef = useRef<HTMLDivElement>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);

  // Openen zet de focus op het eerste item. Dat is wat een menu hoort te doen
  // bij Enter, en het houdt onBlur hieronder kloppend: de focus zit binnen.
  useEffect(() => {
    if (!open) return;
    listRef.current?.querySelector<HTMLButtonElement>('button')?.focus();
  }, [open]);

  // Klikken buiten het menu sluit het. mousedown en niet click: anders sluit
  // het menu pas nadat de klik ergens anders al is aangekomen.
  useEffect(() => {
    if (!open) return;
    function onDown(e: globalThis.MouseEvent) {
      if (!wrapRef.current?.contains(e.target as Node)) setOpen(false);
    }
    document.addEventListener('mousedown', onDown);
    return () => document.removeEventListener('mousedown', onDown);
  }, [open]);

  function items_() {
    return Array.from(listRef.current?.querySelectorAll<HTMLButtonElement>('button') ?? []);
  }

  function onKeyDown(e: KeyboardEvent<HTMLDivElement>) {
    if (e.key === 'Escape') {
      if (!open) return;
      e.stopPropagation();       // laat een onderliggend scherm niet meesluiten
      setOpen(false);
      triggerRef.current?.focus();
      return;
    }
    if (!open || (e.key !== 'ArrowDown' && e.key !== 'ArrowUp')) return;
    e.preventDefault();
    const buttons = items_();
    if (buttons.length === 0) return;
    const here = buttons.indexOf(document.activeElement as HTMLButtonElement);
    const step = e.key === 'ArrowDown' ? 1 : -1;
    buttons[(here + step + buttons.length) % buttons.length]?.focus();
  }

  function onBlur(e: FocusEvent<HTMLDivElement>) {
    if (!wrapRef.current?.contains(e.relatedTarget as Node | null)) setOpen(false);
  }

  return (
    <div className="relative" ref={wrapRef} onKeyDown={onKeyDown} onBlur={onBlur}>
      <button
        ref={triggerRef}
        type="button"
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => setOpen((o) => !o)}
        className={`inline-flex items-center gap-1 rounded-lg px-2 py-1 hover:bg-slate-100 hover:text-slate-900 ${
          open ? 'bg-slate-100 text-slate-900' : ''
        }`}
      >
        {icon}
        {label}
        {badge ? <Badge count={badge} what={badgeTitle ?? `${badge} onderdelen vragen aandacht`} /> : null}
        <ChevronDown size={14} className={`transition-transform ${open ? 'rotate-180' : ''}`} />
      </button>

      {open && (
        // z-40: boven de plakkende apotheekkolom van het weekoverzicht (z-10),
        // onder de modals (z-50) — die openen toch pas nadat dit menu sluit.
        <div
          ref={listRef}
          role="menu"
          aria-label={label}
          className="absolute right-0 z-40 mt-1 min-w-[14rem] rounded-xl border border-slate-200 bg-white py-1 shadow-lg"
        >
          {items.map((it) => (
            <button
              key={it.key}
              type="button"
              role="menuitem"
              title={it.title}
              onClick={() => { setOpen(false); it.onSelect(); }}
              className="flex w-full items-center gap-2 px-3 py-2 text-left text-slate-700 hover:bg-slate-50 focus:bg-slate-100 focus:outline-none"
            >
              <span className="text-slate-500">{it.icon}</span>
              <span className="flex-1">{it.label}</span>
              {it.badge ? <Badge count={it.badge} what={`${it.badge} wacht op jou`} /> : null}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
