-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 025: factuurregels per apotheek
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 025 eerst (of proefdraai 025 met ROLLBACK en daarna dit).
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: één transactie die op ROLLBACK eindigt.
--
-- ┌─ WAAROM set_config VAN DE JWT-CLAIMS ──────────────────────────────────┐
-- │ invoice_lines() controleert op is_privileged(), en die leest            │
-- │ auth.uid(). In de SQL Editor draai je als postgres zonder uid, dus      │
-- │ zonder deze regels weigert de functie en bewijst de test niets.         │
-- └─────────────────────────────────────────────────────────────────────────┘
--
-- OPSTELLING
--   Apotheek A: € 60,00 per uur, starttarief € 10,00
--   Apotheek B: € 40,00 per uur, starttarief €  5,00, maar pas vanaf 100 dagen
--               geleden — zo is "geen tarief op deze datum" te testen zonder een
--               derde apotheek.
--   Afwijkingsgrens: 25%.
--
-- WAT DE TEST DEKT
--   1. Eén apotheek              → volledige duur, uren + starttarief
--   2. Twee apotheken, uitloop   → naar rato omhoog (het voorbeeld uit de opzet)
--   3. Twee apotheken, korter    → naar rato omlaag; geen ondergrens
--   4. Starttarief               → NIET verdeeld: beide apotheken volledig
--   5. Spoed                     → alleen het bedrag, geen uren of starttarief
--   6. Geen declaratie           → geplande uren, gemarkeerd
--   7. Geen tarief op die datum  → gemarkeerd, geen regeltotaal
--   8. Geen budgeted_minutes     → gelijk verdeeld, gemarkeerd
--   9. Reiskosten                → naar rato verdeeld
--  10. Grote afwijking           → gemeld als signaal
--  11. Concept (draft)           → telt niet mee
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
  v_planner UUID;
  v_courier UUID;
  v_a       TEXT;
  v_b       TEXT;
  v_day     DATE := current_date - 5;
  v_old     DATE := current_date - 200;
  v_shift   UUID;
  v_dec     UUID;
  v_km_rate UUID;
  v_row     RECORD;
  v_row_b   RECORD;
BEGIN
  SELECT id INTO v_planner FROM public.user_profiles
   WHERE role IN ('superuser','supervisor','admin') ORDER BY id LIMIT 1;
  IF v_planner IS NULL THEN RAISE EXCEPTION 'OPZET: geen planner in user_profiles.'; END IF;
  SELECT id INTO v_courier FROM public.user_profiles WHERE role = 'courier' ORDER BY id LIMIT 1;
  IF v_courier IS NULL THEN RAISE EXCEPTION 'OPZET: geen koerier in user_profiles.'; END IF;

  SELECT id INTO v_a FROM public.pharmacies ORDER BY id LIMIT 1;
  SELECT id INTO v_b FROM public.pharmacies WHERE id <> v_a ORDER BY id LIMIT 1;
  IF v_b IS NULL THEN RAISE EXCEPTION 'OPZET: er zijn minder dan twee apotheken.'; END IF;

  UPDATE public.invoice_settings SET deviation_pct = 25;

  INSERT INTO public.pharmacy_rates (pharmacy_id, hourly_rate, start_rate, effective_from, note)
  VALUES (v_a, 60.00, 10.00, current_date - 400, 'test 025'),
         (v_b, 40.00,  5.00, current_date - 100, 'test 025')
  ON CONFLICT (pharmacy_id, effective_from) DO UPDATE
    SET hourly_rate = EXCLUDED.hourly_rate, start_rate = EXCLUDED.start_rate;

  -- Kilometervergoeding voor geval 9.
  INSERT INTO public.reimbursement_rates (transport_mode, rate_per_km, threshold_km, effective_from, note)
  VALUES ('bike', 0.2500, 10, current_date - 400, 'test 025')
  ON CONFLICT (transport_mode, effective_from) DO UPDATE SET rate_per_km = EXCLUDED.rate_per_km
  RETURNING id INTO v_km_rate;

  -- Vanaf hier doen we ons voor als de PLANNER.
  PERFORM set_config('request.jwt.claim.sub', v_planner::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_planner, 'role', 'authenticated')::text, true);

  -- ══ GEVAL 1: één apotheek ═══════════════════════════════════════════
  -- Gepland 08:00-12:00 (240), werkelijk tot 12:30 (270). 270/60 × €60 = €270,
  -- plus €10 starttarief.
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '08:00', '12:00', 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id, budgeted_minutes)
  VALUES (v_shift, v_a, 240);
  INSERT INTO public.shift_declarations (shift_id, courier_id, status, token_hash, token_expires_at,
                                         actual_start, actual_end, claims_travel)
  VALUES (v_shift, v_courier, 'submitted', public.declaration_hash_token('t-025-1'),
          now() + INTERVAL '30 days', '08:00', '12:30', false);

  SELECT * INTO v_row FROM public.invoice_lines(v_a, v_day, v_day) WHERE shift_id = v_shift;
  IF v_row.billed_minutes <> 270 THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: % minuten gefactureerd, verwacht 270 (de volledige werkelijke duur).', v_row.billed_minutes;
  END IF;
  IF v_row.hours_amount <> 270.00 OR v_row.start_amount <> 10.00 OR v_row.line_total <> 280.00 THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: uren %, start %, totaal % — verwacht 270 / 10 / 280.',
      v_row.hours_amount, v_row.start_amount, v_row.line_total;
  END IF;
  IF v_row.incomplete THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: volledige regel is toch gemarkeerd (%).', v_row.reason;
  END IF;
  RAISE NOTICE 'GEVAL 1 geslaagd: bij één apotheek gaat de hele duur daarheen.';

  -- ══ GEVAL 2, 4: twee apotheken, dienst loopt uit ════════════════════
  -- Gepland A 120 + B 120 (240), werkelijk 300. Elk 150 minuten.
  -- A: 150/60 × 60 = 150 + 10 start = 160. B: 150/60 × 40 = 100 + 5 = 105.
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '13:00', '17:00', 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id, budgeted_minutes)
  VALUES (v_shift, v_a, 120), (v_shift, v_b, 120);
  INSERT INTO public.shift_declarations (shift_id, courier_id, status, token_hash, token_expires_at,
                                         actual_start, actual_end, claims_travel)
  VALUES (v_shift, v_courier, 'submitted', public.declaration_hash_token('t-025-2'),
          now() + INTERVAL '30 days', '13:00', '18:00', false);

  SELECT * INTO v_row   FROM public.invoice_lines(v_a, v_day, v_day) WHERE shift_id = v_shift;
  SELECT * INTO v_row_b FROM public.invoice_lines(v_b, v_day, v_day) WHERE shift_id = v_shift;

  IF v_row.billed_minutes <> 150 OR v_row_b.billed_minutes <> 150 THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: % en % minuten, verwacht 150 elk (5 uur over twee gelijke helften).',
      v_row.billed_minutes, v_row_b.billed_minutes;
  END IF;
  IF v_row.line_total <> 160.00 OR v_row_b.line_total <> 105.00 THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: totalen % en %, verwacht 160 en 105 (elk eigen uurtarief).',
      v_row.line_total, v_row_b.line_total;
  END IF;
  RAISE NOTICE 'GEVAL 2 geslaagd: uitloop wordt naar rato verdeeld, elk tegen het eigen tarief.';

  IF v_row.start_amount <> 10.00 OR v_row_b.start_amount <> 5.00 THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: starttarieven % en % — beide apotheken horen een VOLLEDIG starttarief te krijgen, niet de helft.',
      v_row.start_amount, v_row_b.start_amount;
  END IF;
  RAISE NOTICE 'GEVAL 4 geslaagd: het starttarief wordt niet verdeeld.';

  -- ══ GEVAL 3: twee apotheken, koerier eerder klaar ═══════════════════
  -- Gepland 240, werkelijk 180 → elk 90 minuten. Geen ondergrens.
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '18:00', '22:00', 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id, budgeted_minutes)
  VALUES (v_shift, v_a, 120), (v_shift, v_b, 120);
  INSERT INTO public.shift_declarations (shift_id, courier_id, status, token_hash, token_expires_at,
                                         actual_start, actual_end, claims_travel)
  VALUES (v_shift, v_courier, 'submitted', public.declaration_hash_token('t-025-3'),
          now() + INTERVAL '30 days', '18:00', '21:00', false);

  SELECT * INTO v_row FROM public.invoice_lines(v_a, v_day, v_day) WHERE shift_id = v_shift;
  IF v_row.billed_minutes <> 90 THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: % minuten, verwacht 90 — korter werken hoort net zo hard door te tellen als uitlopen.', v_row.billed_minutes;
  END IF;
  IF v_row.hours_amount <> 90.00 THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: urenbedrag %, verwacht 90.', v_row.hours_amount;
  END IF;
  RAISE NOTICE 'GEVAL 3 geslaagd: minder gewerkt is minder gefactureerd.';

  -- ══ GEVAL 5: spoed ══════════════════════════════════════════════════
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode, urgent_amount, urgent_note)
  VALUES (v_courier, 'urgent', v_day, '06:00', '07:00', 'planned', 'bike', 75.00, 'telefonisch afgesproken')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id, budgeted_minutes)
  VALUES (v_shift, v_a, 60);
  INSERT INTO public.shift_declarations (shift_id, courier_id, status, token_hash, token_expires_at,
                                         actual_start, actual_end, claims_travel)
  VALUES (v_shift, v_courier, 'submitted', public.declaration_hash_token('t-025-5'),
          now() + INTERVAL '30 days', '06:00', '08:00', false);

  SELECT * INTO v_row FROM public.invoice_lines(v_a, v_day, v_day) WHERE shift_id = v_shift;
  IF v_row.line_total <> 75.00 THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: spoedtotaal %, verwacht 75.', v_row.line_total;
  END IF;
  IF v_row.hours_amount IS NOT NULL OR v_row.start_amount IS NOT NULL THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: bij spoed telt alleen het bedrag, maar er staat % aan uren en % aan starttarief.',
      v_row.hours_amount, v_row.start_amount;
  END IF;
  IF v_row.urgent_note IS NULL THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: de toelichting komt niet mee.';
  END IF;
  -- De declaratie loopt hier 100% uit (60 gepland, 120 werkelijk). Bij spoed
  -- raakt dat het bedrag niet, dus daar hoort geen markering bij: een melding op
  -- een regel die klopt leert de planner om meldingen te negeren.
  IF v_row.incomplete THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: spoedregel is gemarkeerd terwijl het bedrag vaststaat (reden: %).', v_row.reason;
  END IF;
  RAISE NOTICE 'GEVAL 5 geslaagd: spoed factureert alleen het afgesproken bedrag.';

  -- ══ GEVAL 6: geen declaratie ════════════════════════════════════════
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '05:00', '06:00', 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id, budgeted_minutes)
  VALUES (v_shift, v_a, 60);

  SELECT * INTO v_row FROM public.invoice_lines(v_a, v_day, v_day) WHERE shift_id = v_shift;
  IF v_row.billed_minutes <> 60 OR v_row.line_total <> 70.00 THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: % minuten en totaal %, verwacht 60 en 70 (geplande uren).',
      v_row.billed_minutes, v_row.line_total;
  END IF;
  IF v_row.from_declaration THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: de regel doet alsof er een declaratie was.';
  END IF;
  IF NOT v_row.incomplete OR v_row.reason NOT LIKE '%geen ingevulde declaratie%' THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: geplande uren zijn niet gemarkeerd als aanname (reden: %).', v_row.reason;
  END IF;
  RAISE NOTICE 'GEVAL 6 geslaagd: zonder declaratie gaan de geplande uren mee, met markering.';

  -- ══ GEVAL 7: geen tarief op die datum ═══════════════════════════════
  -- Apotheek B heeft pas een tarief vanaf 100 dagen terug; deze dienst is ouder.
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_old, '08:00', '10:00', 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id, budgeted_minutes)
  VALUES (v_shift, v_b, 120);

  SELECT * INTO v_row FROM public.invoice_lines(v_b, v_old, v_old) WHERE shift_id = v_shift;
  IF v_row.line_total IS NOT NULL THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: er staat een totaal van % zonder tarief.', v_row.line_total;
  END IF;
  IF NOT v_row.incomplete OR v_row.reason NOT LIKE '%geen tarief%' THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: ontbrekend tarief is niet gemeld (reden: %).', v_row.reason;
  END IF;
  RAISE NOTICE 'GEVAL 7 geslaagd: zonder tarief geen bedrag, wél een melding.';

  -- ══ GEVAL 8: geen budgeted_minutes bij twee apotheken ═══════════════
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '09:00', '13:00', 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id) VALUES (v_shift, v_a), (v_shift, v_b);
  INSERT INTO public.shift_declarations (shift_id, courier_id, status, token_hash, token_expires_at,
                                         actual_start, actual_end, claims_travel)
  VALUES (v_shift, v_courier, 'submitted', public.declaration_hash_token('t-025-8'),
          now() + INTERVAL '30 days', '09:00', '13:00', false);

  SELECT * INTO v_row FROM public.invoice_lines(v_a, v_day, v_day) WHERE shift_id = v_shift;
  IF v_row.billed_minutes <> 120 THEN
    RAISE EXCEPTION 'GEVAL 8 GEFAALD: % minuten, verwacht 120 (240 gelijk over twee).', v_row.billed_minutes;
  END IF;
  IF NOT v_row.incomplete OR v_row.reason NOT LIKE '%gelijk verdeeld%' THEN
    RAISE EXCEPTION 'GEVAL 8 GEFAALD: de gelijke verdeling is niet gemarkeerd (reden: %).', v_row.reason;
  END IF;
  RAISE NOTICE 'GEVAL 8 geslaagd: zonder verhouding wordt gelijk verdeeld én gemeld.';

  -- ══ GEVAL 9: reiskosten naar rato ═══════════════════════════════════
  -- 20 km × € 0,25 = € 5,00 over twee gelijke helften → € 2,50 elk.
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '14:00', '16:00', 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id, budgeted_minutes)
  VALUES (v_shift, v_a, 60), (v_shift, v_b, 60);
  INSERT INTO public.shift_declarations (shift_id, courier_id, status, token_hash, token_expires_at,
                                         actual_start, actual_end, claims_travel,
                                         computed_reimbursable_km, rate_id)
  VALUES (v_shift, v_courier, 'submitted', public.declaration_hash_token('t-025-9'),
          now() + INTERVAL '30 days', '14:00', '16:00', true, 20.00, v_km_rate)
  RETURNING id INTO v_dec;

  SELECT * INTO v_row   FROM public.invoice_lines(v_a, v_day, v_day) WHERE shift_id = v_shift;
  SELECT * INTO v_row_b FROM public.invoice_lines(v_b, v_day, v_day) WHERE shift_id = v_shift;
  IF v_row.travel_amount <> 2.50 OR v_row_b.travel_amount <> 2.50 THEN
    RAISE EXCEPTION 'GEVAL 9 GEFAALD: reiskosten % en %, verwacht 2,50 elk.',
      v_row.travel_amount, v_row_b.travel_amount;
  END IF;
  RAISE NOTICE 'GEVAL 9 geslaagd: reiskosten worden op dezelfde verhouding verdeeld.';

  -- ══ GEVAL 10: grote afwijking is een signaal ════════════════════════
  -- Gepland 120, werkelijk 360 → 200%.
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '01:00', '03:00', 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id, budgeted_minutes)
  VALUES (v_shift, v_a, 120);
  INSERT INTO public.shift_declarations (shift_id, courier_id, status, token_hash, token_expires_at,
                                         actual_start, actual_end, claims_travel)
  VALUES (v_shift, v_courier, 'submitted', public.declaration_hash_token('t-025-10'),
          now() + INTERVAL '30 days', '01:00', '07:00', false);

  SELECT * INTO v_row FROM public.invoice_lines(v_a, v_day, v_day) WHERE shift_id = v_shift;
  IF NOT v_row.incomplete OR v_row.reason NOT LIKE '%wijkt%' THEN
    RAISE EXCEPTION 'GEVAL 10 GEFAALD: een verdrievoudiging wordt niet gemeld (reden: %).', v_row.reason;
  END IF;
  IF v_row.line_total <> 370.00 THEN
    RAISE EXCEPTION 'GEVAL 10 GEFAALD: totaal %, verwacht 370 — een signaal mag de berekening niet veranderen.', v_row.line_total;
  END IF;
  RAISE NOTICE 'GEVAL 10 geslaagd: een grote afwijking wordt gemeld zonder de factuur te wijzigen.';

  -- ══ GEVAL 11: concepten tellen niet mee ═════════════════════════════
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '23:00', '23:30', 'draft', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id, budgeted_minutes)
  VALUES (v_shift, v_a, 30);

  IF EXISTS (SELECT 1 FROM public.invoice_lines(v_a, v_day, v_day) WHERE shift_id = v_shift) THEN
    RAISE EXCEPTION 'GEVAL 11 GEFAALD: een onbevestigd concept staat op de factuur.';
  END IF;
  RAISE NOTICE 'GEVAL 11 geslaagd: concepten worden niet gefactureerd.';

  RAISE NOTICE 'ALLE GEVALLEN GESLAAGD.';
END $$;

ROLLBACK;
