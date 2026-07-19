import { supabase } from './supabase';
import { DbRole, PLANNER_ROLES, SessionUser } from '../types';

// Haalt de ingelogde gebruiker + rol op uit de Supabase-sessie en user_profiles.
// RLS in de gedeelde DB verwacht een echte auth-sessie (auth.uid()); we leunen
// dus op supabase.auth, niet op een lokale demo-sessie.
export async function loadSessionUser(): Promise<SessionUser | null> {
  if (!supabase) return null;
  const { data: { session } } = await supabase.auth.getSession();
  if (!session) return null;

  const { data: profile, error } = await supabase
    .from('user_profiles')
    .select('id, name, role')
    .eq('id', session.user.id)
    .single();

  if (error || !profile) return null;
  return { id: profile.id, name: profile.name, role: profile.role as DbRole };
}

export function isPlanner(user: SessionUser | null): boolean {
  return !!user && PLANNER_ROLES.includes(user.role);
}

export async function login(email: string, password: string): Promise<SessionUser | null> {
  if (!supabase) throw new Error('Supabase is niet geconfigureerd.');
  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) throw new Error(error.message);
  return loadSessionUser();
}

export async function logout(): Promise<void> {
  if (supabase) await supabase.auth.signOut().catch(() => {});
}
