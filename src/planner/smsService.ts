import { supabase } from '../lib/supabase';
import { SmsLogEntry } from '../types';

function requireClient() {
  if (!supabase) throw new Error('Supabase is niet geconfigureerd.');
  return supabase;
}

// Verstuurstatus per dienst, voor het weekoverzicht. Leesrecht komt van de
// policy "sms_log_privileged_read" (migratie 012).
//
// Waarom dit in de UI staat: het echte risico van een nachtelijke job is niet
// een overgeslagen run — die haalt de sweep in — maar een job die maanden
// geleden stilletjes gestopt is. Door de status naast de dienst te tonen zie je
// dat tijdens je gewone planwerk, zonder aparte monitoring.
export async function getSmsStatusForShifts(shiftIds: string[]): Promise<Map<string, SmsLogEntry>> {
  if (shiftIds.length === 0) return new Map();
  const sb = requireClient();
  const { data, error } = await sb
    .from('shift_sms_log')
    .select('shift_id, status, sent_at, error, phone_e164')
    .in('shift_id', shiftIds);
  if (error) throw error;

  return new Map((data ?? []).map((r: any): [string, SmsLogEntry] => [
    r.shift_id,
    {
      shiftId: r.shift_id,
      status: r.status,
      sentAt: r.sent_at,
      error: r.error,
      phoneE164: r.phone_e164,
    },
  ]));
}
