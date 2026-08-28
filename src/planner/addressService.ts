import { supabase } from '../lib/supabase';
import { CourierDistance, CourierHome } from '../types';

// ── Standplaats en afstanden ──────────────────────────────────────────────
// Het WOONADRES wordt nergens bewaard. Het gaat één keer naar de Edge Function
// courier-distances, die het geocodeert, de route-afstanden berekent en alleen
// die afstanden wegschrijft. Deze module bewaart het adres dus ook niet in een
// state die ergens blijft hangen: het staat in het formulierveld en verdwijnt
// met het scherm.

function requireClient() {
  if (!supabase) throw new Error('Supabase is niet geconfigureerd.');
  return supabase;
}

export async function getCourierHomes(): Promise<CourierHome[]> {
  const sb = requireClient();
  const { data, error } = await sb.rpc('courier_home_overview');
  if (error) throw error;
  return (data ?? []).map((r: any): CourierHome => ({
    courierId: r.courier_id,
    courierName: r.courier_name,
    homePharmacyId: r.home_pharmacy_id,
    distances: r.distances ?? 0,
    computedAt: r.computed_at,
  }));
}

export async function setHomePharmacy(courierId: string, pharmacyId: string | null): Promise<void> {
  const sb = requireClient();
  const { error } = await sb.rpc('set_home_pharmacy', {
    p_courier_id: courierId, p_pharmacy_id: pharmacyId,
  });
  if (error) throw error;
}

export async function getDistances(courierId: string): Promise<CourierDistance[]> {
  const sb = requireClient();
  const { data, error } = await sb
    .from('courier_distances')
    .select('courier_id, pharmacy_id, distance_km, source, computed_at')
    .eq('courier_id', courierId);
  if (error) throw error;
  return (data ?? []).map((r: any): CourierDistance => ({
    courierId: r.courier_id,
    pharmacyId: r.pharmacy_id,
    distanceKm: Number(r.distance_km),
    source: r.source,
    computedAt: r.computed_at,
  }));
}

// Handmatige correctie, bijvoorbeeld zolang een apotheek nog geen adresgegevens
// heeft. Komt in de database als source = 'manual', zodat later zichtbaar is dat
// dit getal niet uit een routeberekening komt.
export async function setDistanceManual(
  courierId: string, pharmacyId: string, km: number,
): Promise<void> {
  const sb = requireClient();
  const { error } = await sb.rpc('set_courier_distance', {
    p_courier_id: courierId, p_pharmacy_id: pharmacyId, p_distance_km: km,
  });
  if (error) throw error;
}

export interface DistanceResult {
  pharmacy_id: string;
  pharmacy_name: string;
  distance_km: number;
  source: 'route' | 'fallback' | 'manual';
}

export interface DistanceRun {
  distances: DistanceResult[];
  fallbacks: number;
  skipped: { id: string; name: string; reason: string }[];
}

// Adres → afstanden. De Edge Function controleert zelf of de aanroeper planner
// is; we sturen daarvoor het sessietoken mee. Het adres gaat één keer over de
// lijn en komt nergens terug.
export async function computeDistances(courierId: string, address: string): Promise<DistanceRun> {
  const sb = requireClient();
  const { data: { session } } = await sb.auth.getSession();
  if (!session) throw new Error('Je sessie is verlopen. Log opnieuw in.');

  const url = `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/courier-distances`;
  const res = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'apikey': import.meta.env.VITE_SUPABASE_ANON_KEY as string,
      'Authorization': `Bearer ${session.access_token}`,
    },
    body: JSON.stringify({ courier_id: courierId, address }),
  });

  let body: any = null;
  try { body = await res.json(); } catch { /* leeg antwoord */ }
  if (!res.ok) throw new Error(body?.error ?? 'Berekenen mislukt.');

  return {
    distances: body?.distances ?? [],
    fallbacks: body?.fallbacks ?? 0,
    skipped: body?.skipped ?? [],
  };
}

export const SOURCE_LABELS: Record<string, string> = {
  route:    'route',
  fallback: 'schatting',
  manual:   'handmatig',
};
