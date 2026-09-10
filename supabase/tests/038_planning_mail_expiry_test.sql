-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 038: leeftijdscontrole voor planningsberichten
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 038 eerst (of proefdraai 038 met ROLLBACK en daarna dit).
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: één transactie die op ROLLBACK eindigt. De functie raakt
-- ook echte wachtende rijen aan, en juist daarom eindigt dit bestand op ROLLBACK.
--
-- OPSTELLING — zeven wachtende berichten voor één koerier:
--   A  shift_confirmed,    dienst gisteren            → moet vervallen
--   B  shift_confirmed,    dienst over twee dagen     → moet blijven
--   C  shift_changed,      dienst gisteren            → moet vervallen
--   D  shift_cancelled,    dienst gisteren            → moet BLIJVEN (uitzondering)
--   E  schedule_confirmed, einddatum gisteren         → moet vervallen
--   F  schedule_confirmed, einddatum leeg             → moet blijven
--   G  shift_confirmed,    lege shifts-lijst          → moet blijven (eigen pad)
--
-- WAT DE TEST DEKT
--   1. Een begonnen dienst vervalt, met de reden erbij
--   2. Een dienst die nog moet beginnen blijft staan
--   3. shift_changed gaat mee in de controle
--   4. shift_cancelled valt er bewust buiten — het bewijs dát er afgemeld is
--   5. Een afspraak met een verstreken einddatum vervalt, met de datum in de reden
--   6. Een afspraak zonder einddatum blijft staan
--   7. Een lege shifts-lijst blijft staan: die heeft zijn eigen afsluiting
--   8. Een tweede aanroep verandert niets meer (idempotent)
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
  v_courier UUID;
  v_a UUID; v_b UUID; v_c UUID; v_d UUID; v_e UUID; v_f UUID; v_g UUID;
  v_n      INT;
  v_row    RECORD;
  v_gisteren DATE := current_date - 1;
  v_straks   DATE := current_date + 2;
BEGIN
  SELECT id INTO v_courier FROM public.user_profiles WHERE role = 'courier' ORDER BY id LIMIT 1;
  IF v_courier IS NULL THEN RAISE EXCEPTION 'OPZET: geen koerier in user_profiles.'; END IF;

  -- ── A: begonnen dienst ─────────────────────────────────────────────────
  INSERT INTO public.mail_outbox (courier_id, kind, subject_type, payload)
  VALUES (v_courier, 'shift_confirmed', 'shift', jsonb_build_object(
    'subject_type', 'shift', 'shifts', jsonb_build_array(jsonb_build_object(
      'shift_date', v_gisteren, 'weekday', 1, 'start_time', '08:00',
      'budgeted_end_time', '12:00', 'transport_mode', 'bike', 'pharmacies', '[]'::jsonb))))
  RETURNING id INTO v_a;

  -- ── B: dienst die nog moet beginnen ────────────────────────────────────
  INSERT INTO public.mail_outbox (courier_id, kind, subject_type, payload)
  VALUES (v_courier, 'shift_confirmed', 'shift', jsonb_build_object(
    'subject_type', 'shift', 'shifts', jsonb_build_array(jsonb_build_object(
      'shift_date', v_straks, 'weekday', 1, 'start_time', '08:00',
      'budgeted_end_time', '12:00', 'transport_mode', 'bike', 'pharmacies', '[]'::jsonb))))
  RETURNING id INTO v_b;

  -- ── C: shift_changed, begonnen ─────────────────────────────────────────
  INSERT INTO public.mail_outbox (courier_id, kind, subject_type, payload)
  VALUES (v_courier, 'shift_changed', 'shift', jsonb_build_object(
    'subject_type', 'shift', 'shifts', jsonb_build_array(jsonb_build_object(
      'shift_date', v_gisteren, 'weekday', 1, 'start_time', '08:00',
      'budgeted_end_time', '12:00', 'transport_mode', 'bike', 'pharmacies', '[]'::jsonb))))
  RETURNING id INTO v_c;

  -- ── D: afmelding over een dienst van gisteren ──────────────────────────
  INSERT INTO public.mail_outbox (courier_id, kind, subject_type, payload)
  VALUES (v_courier, 'shift_cancelled', 'shift', jsonb_build_object(
    'subject_type', 'shift', 'shift_date', v_gisteren, 'weekday', 1,
    'start_time', '08:00', 'budgeted_end_time', '12:00',
    'pharmacies', '[]'::jsonb, 'reason', 'verwijderd'))
  RETURNING id INTO v_d;

  -- ── E: afspraak met verstreken einddatum ───────────────────────────────
  INSERT INTO public.mail_outbox (courier_id, kind, subject_type, payload)
  VALUES (v_courier, 'schedule_confirmed', 'schedule', jsonb_build_object(
    'subject_type', 'schedule', 'end_date', v_gisteren,
    'shifts', jsonb_build_array(jsonb_build_object(
      'shift_date', v_straks, 'weekday', 1, 'start_time', '08:00',
      'budgeted_end_time', '12:00', 'transport_mode', 'bike', 'pharmacies', '[]'::jsonb))))
  RETURNING id INTO v_e;

  -- ── F: afspraak zonder einddatum ───────────────────────────────────────
  INSERT INTO public.mail_outbox (courier_id, kind, subject_type, payload)
  VALUES (v_courier, 'schedule_confirmed', 'schedule', jsonb_build_object(
    'subject_type', 'schedule', 'end_date', NULL,
    'shifts', jsonb_build_array(jsonb_build_object(
      'shift_date', v_gisteren, 'weekday', 1, 'start_time', '08:00',
      'budgeted_end_time', '12:00', 'transport_mode', 'bike', 'pharmacies', '[]'::jsonb))))
  RETURNING id INTO v_f;

  -- ── G: lege dienstenlijst ──────────────────────────────────────────────
  INSERT INTO public.mail_outbox (courier_id, kind, subject_type, payload)
  VALUES (v_courier, 'shift_confirmed', 'shift', jsonb_build_object(
    'subject_type', 'shift', 'shifts', '[]'::jsonb))
  RETURNING id INTO v_g;

  PERFORM public.mail_expire_stale_planning();

  -- ── 1. Begonnen dienst vervalt, met reden ──────────────────────────────
  SELECT status, error INTO v_row FROM public.mail_outbox WHERE id = v_a;
  IF v_row.status <> 'expired' THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: A staat op %, verwacht expired — een bericht over een '
                    'begonnen dienst blijft dus eeuwig wachten.', v_row.status;
  END IF;
  IF v_row.error <> 'de dienst is al begonnen' THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: reden bij A is "%", verwacht "de dienst is al begonnen".',
                    v_row.error;
  END IF;

  -- ── 2. Dienst die nog moet beginnen blijft ─────────────────────────────
  SELECT status INTO v_row FROM public.mail_outbox WHERE id = v_b;
  IF v_row.status <> 'pending' THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: B staat op %, verwacht pending — de controle ruimt '
                    'berichten op die nog moeten uitgaan.', v_row.status;
  END IF;

  -- ── 3. shift_changed gaat mee ──────────────────────────────────────────
  SELECT status INTO v_row FROM public.mail_outbox WHERE id = v_c;
  IF v_row.status <> 'expired' THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: C (shift_changed) staat op %, verwacht expired.', v_row.status;
  END IF;

  -- ── 4. shift_cancelled blijft — de bewuste uitzondering ────────────────
  SELECT status INTO v_row FROM public.mail_outbox WHERE id = v_d;
  IF v_row.status <> 'pending' THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: D (shift_cancelled) staat op %, verwacht pending. Een '
                    'afmelding is het bewijs dát er gemeld is en moet altijd uitgaan — een '
                    'koerier die niets hoort gaat er misschien alsnog heen.', v_row.status;
  END IF;

  -- ── 5. Afspraak met verstreken einddatum vervalt ───────────────────────
  SELECT status, error INTO v_row FROM public.mail_outbox WHERE id = v_e;
  IF v_row.status <> 'expired' THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: E staat op %, verwacht expired.', v_row.status;
  END IF;
  IF v_row.error NOT LIKE 'de afspraak is op % afgelopen' THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: reden bij E is "%" — de einddatum hoort erin te staan.',
                    v_row.error;
  END IF;

  -- ── 6. Afspraak zonder einddatum blijft ────────────────────────────────
  -- Ook al liggen de datums in shifts[] in het verleden: die zijn hier niet de
  -- horizon. Zo'n bericht is onvolledig, niet onwaar.
  SELECT status INTO v_row FROM public.mail_outbox WHERE id = v_f;
  IF v_row.status <> 'pending' THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: F staat op %, verwacht pending — een open afspraak heeft '
                    'geen moment waarop hij verstrijkt.', v_row.status;
  END IF;

  -- ── 7. Lege dienstenlijst blijft: eigen afsluiting ─────────────────────
  SELECT status INTO v_row FROM public.mail_outbox WHERE id = v_g;
  IF v_row.status <> 'pending' THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: G staat op %, verwacht pending — een lege lijst hoort '
                    'door de verzender afgesloten te worden met zijn eigen reden, niet hier '
                    'met een bewering over diensten die er niet in staan.', v_row.status;
  END IF;

  -- ── 8. Idempotent ──────────────────────────────────────────────────────
  SELECT public.mail_expire_stale_planning() INTO v_n;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'GEVAL 8 GEFAALD: een tweede aanroep raakte % rij(en) aan, verwacht 0.', v_n;
  END IF;

  RAISE NOTICE 'Alle 8 gevallen geslaagd.';
END $$;

-- ────────────────────────────────────────────────────────────────────────
-- Stand na afloop, ter controle vóór de rollback.
-- ────────────────────────────────────────────────────────────────────────
SELECT kind, status, count(*) FROM public.mail_outbox
GROUP BY kind, status ORDER BY kind, status;

ROLLBACK;   -- er blijft niets van deze test achter
