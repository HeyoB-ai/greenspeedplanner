-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 028: onkosten bij de nadeclaratie
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 028 eerst (of proefdraai 028 met ROLLBACK en daarna dit).
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: één transactie die op ROLLBACK eindigt.
--
-- ┌─ WAT DEZE TEST NIET KAN CONTROLEREN ───────────────────────────────────┐
-- │ Of "bon verwacht" bij de juiste koeriers aan gaat. Dat hangt aan        │
-- │ employmentType, een veld dat deze repo niet kent; bestaat de kolom niet │
-- │ of is hij leeg, dan is het antwoord overal false. De test controleert   │
-- │ daarom alleen het deel dat sowieso moet kloppen: zonder onkosten nooit  │
-- │ een markering. Zie de verificatiequery onderaan migratie 028.           │
-- └─────────────────────────────────────────────────────────────────────────┘
--
-- WAT DE TEST DEKT
--   1. Posten vastleggen        → komen in de tabel, lege regels vallen weg
--   2. Invulpagina              → krijgt de posten terug via het token
--   3. Plannerscherm            → totaal klopt; geen onkosten = geen markering
--   4. Facturatie               → naar rato verdeeld over twee apotheken
--   5. Fout bedrag              → duidelijke melding, niets opgeslagen
--   6. Goedgekeurde declaratie  → weigert met 45003 (migratie 022)
--   7. Opnieuw vastleggen       → vervangt, stapelt niet
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
  v_planner UUID;
  v_courier UUID;
  v_a       TEXT;
  v_b       TEXT;
  v_day     DATE := current_date - 3;
  v_shift   UUID;
  v_dec     UUID;
  v_token   TEXT := 'test-token-028';
  v_row     RECORD;
  v_row_b   RECORD;
  v_n       INT;
  v_state   TEXT;
  v_msg     TEXT;
BEGIN
  SELECT id INTO v_planner FROM public.user_profiles
   WHERE role IN ('superuser','supervisor','admin') ORDER BY id LIMIT 1;
  IF v_planner IS NULL THEN RAISE EXCEPTION 'OPZET: geen planner in user_profiles.'; END IF;
  SELECT id INTO v_courier FROM public.user_profiles WHERE role = 'courier' ORDER BY id LIMIT 1;
  IF v_courier IS NULL THEN RAISE EXCEPTION 'OPZET: geen koerier in user_profiles.'; END IF;
  SELECT id INTO v_a FROM public.pharmacies ORDER BY id LIMIT 1;
  SELECT id INTO v_b FROM public.pharmacies WHERE id <> v_a ORDER BY id LIMIT 1;
  IF v_b IS NULL THEN RAISE EXCEPTION 'OPZET: er zijn minder dan twee apotheken.'; END IF;

  INSERT INTO public.pharmacy_rates (pharmacy_id, hourly_rate, start_rate, effective_from, note)
  VALUES (v_a, 60.00, 10.00, current_date - 400, 'test 028'),
         (v_b, 40.00,  5.00, current_date - 400, 'test 028')
  ON CONFLICT (pharmacy_id, effective_from) DO UPDATE
    SET hourly_rate = EXCLUDED.hourly_rate, start_rate = EXCLUDED.start_rate;

  -- Een gedeelde dienst, half om half, met een ingevulde declaratie.
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, budgeted_end_time,
                             status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '08:00', '12:00', 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id, budgeted_minutes)
  VALUES (v_shift, v_a, 120), (v_shift, v_b, 120);
  INSERT INTO public.shift_declarations (shift_id, courier_id, status, token_hash, token_expires_at,
                                         actual_start, actual_end, claims_travel)
  VALUES (v_shift, v_courier, 'submitted', public.declaration_hash_token(v_token),
          now() + INTERVAL '30 days', '08:00', '12:00', false)
  RETURNING id INTO v_dec;

  -- ══ GEVAL 1: posten vastleggen ══════════════════════════════════════
  -- Drie regels, waarvan één helemaal leeg: die hoort te verdwijnen zonder fout,
  -- want het formulier begint met een lege regel.
  SELECT public.declaration_set_expenses(v_token, '[
    {"description": "parkeren centrum",   "amount_eur": "4.50"},
    {"description": "",                   "amount_eur": ""},
    {"description": "veerpont",           "amount_eur": "3.50"}
  ]'::JSONB) INTO v_n;

  IF v_n <> 2 THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: % posten opgeslagen, verwacht 2 (de lege regel hoort weg te vallen).', v_n;
  END IF;
  IF (SELECT sum(amount_eur) FROM public.declaration_expenses WHERE declaration_id = v_dec) <> 8.00 THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: totaal klopt niet.';
  END IF;
  RAISE NOTICE 'GEVAL 1 geslaagd: twee posten vastgelegd, de lege regel viel weg.';

  -- ══ GEVAL 2: de invulpagina krijgt ze terug ═════════════════════════
  SELECT * INTO v_row FROM public.declaration_by_token(v_token);
  IF v_row.expenses IS NULL OR jsonb_array_length(v_row.expenses) <> 2 THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: de pagina krijgt % posten terug.',
      COALESCE(jsonb_array_length(v_row.expenses)::TEXT, 'geen');
  END IF;
  IF v_row.expenses -> 0 ->> 'description' <> 'parkeren centrum' THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: verkeerde volgorde of inhoud (%).', v_row.expenses;
  END IF;
  IF v_row.expects_receipt IS NULL THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: expects_receipt is NULL; verwacht true of false.';
  END IF;
  RAISE NOTICE 'GEVAL 2 geslaagd: de posten komen terug op de invulpagina (bon verwacht: %).', v_row.expects_receipt;

  -- ══ GEVAL 3: het plannerscherm ══════════════════════════════════════
  PERFORM set_config('request.jwt.claim.sub', v_planner::text, true);
  PERFORM set_config('request.jwt.claims',
                     json_build_object('sub', v_planner, 'role', 'authenticated')::text, true);

  SELECT * INTO v_row FROM public.declaration_overview(v_day, v_day)
   WHERE declaration_id = v_dec;
  IF v_row.expenses_amount <> 8.00 THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: onkostentotaal %, verwacht 8,00.', v_row.expenses_amount;
  END IF;
  IF jsonb_array_length(v_row.expenses) <> 2 THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: de posten zelf komen niet mee.';
  END IF;
  RAISE NOTICE 'GEVAL 3 geslaagd: het plannerscherm ziet de posten en het totaal.';

  -- ══ GEVAL 4: facturatie, naar rato ══════════════════════════════════
  -- € 8,00 over twee gelijke helften → € 4,00 elk, zonder marge.
  SELECT * INTO v_row   FROM public.invoice_lines(v_a, v_day, v_day) WHERE shift_id = v_shift;
  SELECT * INTO v_row_b FROM public.invoice_lines(v_b, v_day, v_day) WHERE shift_id = v_shift;

  IF v_row.expenses_amount <> 4.00 OR v_row_b.expenses_amount <> 4.00 THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: onkosten % en %, verwacht 4,00 elk.',
      v_row.expenses_amount, v_row_b.expenses_amount;
  END IF;
  -- A: 120 min × €60 = 120 + 10 start + 4 onkosten = 134.
  IF v_row.line_total <> 134.00 THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: regeltotaal %, verwacht 134 (120 uren + 10 start + 4 onkosten).',
      v_row.line_total;
  END IF;
  RAISE NOTICE 'GEVAL 4 geslaagd: onkosten worden naar rato doorbelast en tellen mee in het totaal.';

  -- ══ GEVAL 5: een bedrag dat niet kan ════════════════════════════════
  BEGIN
    PERFORM public.declaration_set_expenses(v_token,
      '[{"description": "parkeren", "amount_eur": "0"}]'::JSONB);
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: een bedrag van 0 werd geaccepteerd.';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT;
    IF v_msg LIKE 'GEVAL 5 GEFAALD%' THEN RAISE; END IF;
    RAISE NOTICE 'GEVAL 5 geslaagd: een onbruikbaar bedrag wordt geweigerd (%).', v_msg;
  END;

  -- ══ GEVAL 7: opnieuw vastleggen vervangt ════════════════════════════
  SELECT public.declaration_set_expenses(v_token,
    '[{"description": "alleen parkeren", "amount_eur": "2.25"}]'::JSONB) INTO v_n;
  IF v_n <> 1 OR (SELECT count(*) FROM public.declaration_expenses WHERE declaration_id = v_dec) <> 1 THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: opnieuw vastleggen stapelde in plaats van te vervangen.';
  END IF;
  RAISE NOTICE 'GEVAL 7 geslaagd: de lijst wordt vervangen, niet aangevuld.';

  -- ══ GEVAL 6: goedgekeurd → dicht ════════════════════════════════════
  UPDATE public.shift_declarations SET status = 'approved', reviewed_at = now() WHERE id = v_dec;
  BEGIN
    PERFORM public.declaration_set_expenses(v_token,
      '[{"description": "nog een post", "amount_eur": "1.00"}]'::JSONB);
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: er kon nog een post bij op een goedgekeurde declaratie.';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    IF v_msg LIKE 'GEVAL 6 GEFAALD%' THEN RAISE; END IF;
    IF v_state <> '45003' THEN
      RAISE EXCEPTION 'GEVAL 6 GEFAALD: SQLSTATE % (%), verwacht 45003.', v_state, v_msg;
    END IF;
    RAISE NOTICE 'GEVAL 6 geslaagd: na goedkeuring kunnen er geen posten meer bij.';
  END;

  -- ══ Aanvulling bij geval 3: geen onkosten = geen markering ══════════
  DELETE FROM public.declaration_expenses WHERE declaration_id = v_dec;
  UPDATE public.shift_declarations SET status = 'submitted', reviewed_at = NULL WHERE id = v_dec;

  SELECT * INTO v_row FROM public.declaration_overview(v_day, v_day)
   WHERE declaration_id = v_dec;
  IF v_row.expects_receipt THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: "bon verwacht" staat aan zonder onkosten — dat is ruis.';
  END IF;
  IF v_row.expenses_amount <> 0 THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: onkostentotaal % zonder posten, verwacht 0.', v_row.expenses_amount;
  END IF;
  RAISE NOTICE 'GEVAL 3 geslaagd (vervolg): zonder onkosten geen markering en een totaal van 0.';

  RAISE NOTICE 'ALLE GEVALLEN GESLAAGD.';
END $$;

ROLLBACK;
