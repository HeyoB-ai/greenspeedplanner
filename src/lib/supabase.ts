import { createClient, SupabaseClient } from '@supabase/supabase-js';

// Zelfde env-conventie als de hoofd-app (Greenspeed-AIrouteplanner):
// VITE_SUPABASE_URL + VITE_SUPABASE_ANON_KEY. Praat met dezelfde database.
const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

export const supabase: SupabaseClient | null =
  url && anonKey ? createClient(url, anonKey) : null;

export const isConfigured = !!supabase;
