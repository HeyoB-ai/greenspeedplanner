import { supabase } from '../lib/supabase';
import { CourierContact } from '../types';
import { addDays, toISODate } from './dates';

function requireClient() {
  if (!supabase) throw new Error('Supabase is niet geconfigureerd.');
  return supabase;
}

// ── Nummerinvoer normaliseren ─────────────────────────────────────────────
// De nummers komen uit een ander systeem en worden met de hand overgetypt, dus
// in elke schrijfwijze: '06 12 34 56 78', '06-12345678', '0031612345678',
// '+31 6 12345678'. We rekenen ze om naar E.164 omdat de provider dat eist en
// omdat twee schrijfwijzen van hetzelfde nummer anders naast elkaar gaan leven.
//
// Bewust conservatief: wat we niet met zekerheid kunnen lezen, geven we terug
// als null met een leesbare reden. Fout gokken is duurder dan doorvragen — een
// verkeerd geraden nummer levert een SMS bij een vreemde af.
export type PhoneParse =
  | { ok: true;  e164: string }
  | { ok: false; reason: string };

const E164 = /^\+[1-9][0-9]{7,14}$/;   // zelfde regel als de CHECK in migratie 011

export function normalizePhone(raw: string): PhoneParse {
  const s = raw.replace(/[\s\-(). ]/g, '');
  if (!s) return { ok: false, reason: 'Geen nummer ingevuld.' };
  if (/[^0-9+]/.test(s)) return { ok: false, reason: 'Alleen cijfers, spaties en een + zijn toegestaan.' };

  let e164: string;
  if (s.startsWith('+'))       e164 = s;                       // al internationaal
  else if (s.startsWith('00')) e164 = `+${s.slice(2)}`;        // 0031… → +31…
  else if (s.startsWith('0'))  e164 = `+31${s.slice(1)}`;      // 06… → +316…
  else if (s.startsWith('31')) e164 = `+${s}`;                 // 31612345678
  else if (s.startsWith('6') && s.length === 9) e164 = `+31${s}`; // 612345678
  else return { ok: false, reason: 'Onduidelijk nummer — noteer het als 06… of +316….' };

  if (!E164.test(e164)) return { ok: false, reason: `'${e164}' is geen geldig telefoonnummer.` };
  return { ok: true, e164 };
}

// Waarschuwing (géén blokkade) voor iets dat geldig is maar waarschijnlijk geen
// mobiel nummer is. Een SMS naar een vaste lijn verdwijnt geruisloos, dus dit
// is precies het geval waar je een seintje wilt en geen slot.
export function phoneWarning(e164: string): string | null {
  if (e164.startsWith('+316')) {
    return e164.length === 12 ? null : 'Nederlands mobiel nummer heeft 9 cijfers na +31 (bv. +31612345678).';
  }
  if (e164.startsWith('+31')) return 'Dit lijkt een vast Nederlands nummer — SMS komt dan niet aan.';
  return 'Buitenlands nummer — controleer of SMS daarheen gewenst is.';
}

// ── Opslag ────────────────────────────────────────────────────────────────

export async function getContacts(): Promise<CourierContact[]> {
  const sb = requireClient();
  const { data, error } = await sb
    .from('courier_contacts')
    .select('courier_id, phone_e164, note, updated_at');
  if (error) throw error;
  return (data ?? []).map((r: any): CourierContact => ({
    courierId: r.courier_id,
    phoneE164: r.phone_e164,
    note: r.note,
    updatedAt: r.updated_at,
  }));
}

// Eén nummer per koerier → upsert op de primaire sleutel.
export async function saveContact(courierId: string, phoneE164: string, note: string | null): Promise<void> {
  const sb = requireClient();
  const { data: { session } } = await sb.auth.getSession();
  const { error } = await sb
    .from('courier_contacts')
    .upsert({
      courier_id: courierId,
      phone_e164: phoneE164,
      note,
      updated_at: new Date().toISOString(),
      updated_by: session?.user.id ?? null,
    }, { onConflict: 'courier_id' });
  if (error) throw error;
}

export async function deleteContact(courierId: string): Promise<void> {
  const sb = requireClient();
  const { error } = await sb.from('courier_contacts').delete().eq('courier_id', courierId);
  if (error) throw error;
}

// Koeriers met bevestigde diensten in de komende periode. Gebruikt om in het
// beheerscherm te tonen wie een nummer mist terwijl er al een dienst voor hem
// staat — anders merk je een ontbrekend nummer pas als de SMS uitblijft.
export async function getCouriersWithUpcomingShifts(days = 14): Promise<Set<string>> {
  const sb = requireClient();
  const today = new Date();
  const { data, error } = await sb
    .from('shifts')
    .select('courier_id')
    .eq('status', 'planned')
    .not('courier_id', 'is', null)
    .gte('shift_date', toISODate(today))
    .lte('shift_date', toISODate(addDays(today, days)));
  if (error) throw error;
  return new Set((data ?? []).map((r: any) => r.courier_id as string));
}
