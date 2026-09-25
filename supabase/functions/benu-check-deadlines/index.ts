// ════════════════════════════════════════════════════════════════════════
// Greenspeed Planner — BENU: extra tijd goedkeuren na het verstrijken van 48 uur
// ════════════════════════════════════════════════════════════════════════
// Supabase Edge Function (Deno). Draait via een cron-schedule; zie de README
// voor het opzetten daarvan.
//
// Eén aanroep, verder niets: benu_check_deadlines() (migratie 046) zet elke
// melding die op 'submitted' staat en waarvan dispute_deadline voorbij is op
// 'auto_approved', en geeft terug hoeveel rijen dat waren.
//
// Geen mail. De apotheek is bij het indienen al gewaarschuwd dat zonder reactie
// automatisch wordt goedgekeurd; een tweede bericht dat zegt "we hebben gedaan
// wat we aankondigden" voegt niets toe en komt aan als een verwijt.
//
// Het draaien is idempotent: wat al 'auto_approved' is valt buiten de WHERE, dus
// een dubbele run of een inhaalslag na een overgeslagen schedule verandert niets
// extra's. De frequentie bepaalt alleen hoe scherp de 48 uur wordt nageleefd.
// ════════════════════════════════════════════════════════════════════════

import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const SUPABASE_URL     = Deno.env.get('SUPABASE_URL') ?? '';
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const CRON_SECRET      = Deno.env.get('CRON_SECRET') ?? '';

Deno.serve(async (req) => {
  // Extra slot bovenop de JWT-controle van Supabase: als CRON_SECRET gezet is,
  // moet de aanroeper hem meesturen. Zo kan een geldig maar ongerelateerd token
  // deze functie niet triggeren.
  if (CRON_SECRET && req.headers.get('x-cron-secret') !== CRON_SECRET) {
    return json({ error: 'Niet toegestaan' }, 401);
  }

  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
    return json({ error: 'SUPABASE_URL/SUPABASE_SERVICE_ROLE_KEY ontbreken' }, 500);
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const { data, error } = await admin.rpc('benu_check_deadlines');
  if (error) {
    console.error('[benu-deadlines] benu_check_deadlines mislukt:', error.message);
    return json({ error: error.message }, 500);
  }

  // De RPC geeft één getal terug; supabase-js levert dat als scalar, maar een
  // enkelrijige TABLE-vorm zou als array binnenkomen. Beide vormen opvangen is
  // goedkoper dan erop vertrouwen.
  const raw = Array.isArray(data) ? data[0] : data;
  const autoApproved = Number(raw ?? 0);

  console.log('[benu-deadlines]', JSON.stringify({ auto_approved: autoApproved }));
  return json({ auto_approved: autoApproved }, 200);
});

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status, headers: { 'Content-Type': 'application/json' },
  });
}
