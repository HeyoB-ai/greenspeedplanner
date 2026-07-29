-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 016: aankondigingen, sweep en outbox
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 016 eerst (of proefdraai 016 met ROLLBACK en daarna dit).
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: één transactie die op ROLLBACK eindigt.
--
-- De test maakt zijn eigen roosterregel (inactief, zodat de generator hem
-- negeert) en zet er diensten onder in de toekomst. Alle tellingen zijn
-- afgebakend op die regel en die koerier, zodat bestaande planning niet meetelt.
--
-- WAT DE TEST DEKT — de beslistabel uit docs/FASE5_MAIL_ONTWERP.md
--   1. Bevestigde afspraak zonder aankondiging → één bericht, niet tien
--   2. Later nóg een dienst op dezelfde tijd   → GEEN bericht (rule 3 van de opzet)
--   3. Nieuwe variant erbij (tijd gewijzigd)   → bericht, en de variant is gedekt
--   4. Variant weggewijzigd (het spiegelbeeld) → bericht, dank zij dirtied_at
--   5. Versmallen zonder ingreep (klok)        → GEEN bericht
--   6. Losse dienst (geen schedule_id)         → eigen subject, eigen bericht
--   7. Dienst verwijderen                      → afmelding met gekopieerde gegevens
--   8. Koerierwissel                           → afmelding voor de OUDE koerier
--   9. Sweep twee keer draaien                 → geen extra berichten
--  10. Aanpassen en terugzetten                → geen bericht, én de vlag gewist
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
  v_courier  UUID;
  v_courier2 UUID;
  v_pharm    TEXT;
  v_planner  UUID;
  v_sched    UUID;
  v_s1       UUID;
  v_s2       UUID;
  v_s3       UUID;
  v_los      UUID;
  v_d1       DATE := current_date + 7;
  v_d2       DATE := current_date + 14;
  v_d3       DATE := current_date + 21;
  v_mails    INT;
  v_before   INT;
  v_cov      TEXT[];
  v_dirty    TIMESTAMPTZ;
  v_payload  JSONB;
BEGIN
  -- ── Voorbereiding ────────────────────────────────────────────────────
  SELECT id INTO v_courier FROM public.user_profiles WHERE role = 'courier' ORDER BY id LIMIT 1;
  SELECT id INTO v_courier2 FROM public.user_profiles WHERE role = 'courier' AND id <> v_courier ORDER BY id LIMIT 1;
  IF v_courier IS NULL THEN
    RAISE EXCEPTION 'OPZET: geen koerier in user_profiles.';
  END IF;
  SELECT id INTO v_pharm FROM public.pharmacies LIMIT 1;
  IF v_pharm IS NULL THEN RAISE EXCEPTION 'OPZET: geen apotheek in pharmacies.'; END IF;
  SELECT id INTO v_planner FROM public.user_profiles
   WHERE role IN ('superuser','supervisor','admin') LIMIT 1;

  -- Roosterregel met déze koerier als vaste koerier; inactief zodat de
  -- generator hem negeert.
  INSERT INTO public.pharmacy_schedules
    (pharmacy_id, weekday, start_time, budgeted_end_time, courier_id, start_date, is_active)
  VALUES (v_pharm, EXTRACT(ISODOW FROM v_d1)::INT, '07:45', '12:00', v_courier, current_date, false)
  RETURNING id INTO v_sched;

  -- Twee bevestigde diensten uit die regel, zelfde tijd.
  INSERT INTO public.shifts
    (courier_id, shift_type, shift_date, start_time, budgeted_end_time, status, schedule_id)
  VALUES (v_courier, 'regular', v_d1, '07:45', '12:00', 'planned', v_sched) RETURNING id INTO v_s1;
  INSERT INTO public.shifts
    (courier_id, shift_type, shift_date, start_time, budgeted_end_time, status, schedule_id)
  VALUES (v_courier, 'regular', v_d2, '07:45', '12:00', 'planned', v_sched) RETURNING id INTO v_s2;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id) VALUES (v_s1, v_pharm), (v_s2, v_pharm);

  -- ── GEVAL 1: één bericht voor twee diensten uit dezelfde afspraak ─────
  PERFORM public.mail_sweep();

  SELECT count(*) INTO v_mails FROM public.mail_outbox
   WHERE subject_id = v_sched AND courier_id = v_courier;
  IF v_mails <> 1 THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: % berichten voor twee diensten uit één afspraak, verwacht 1.', v_mails;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.mail_outbox
                  WHERE subject_id = v_sched AND kind = 'schedule_confirmed') THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: bericht heeft niet kind schedule_confirmed.';
  END IF;
  RAISE NOTICE 'GEVAL 1 geslaagd: twee diensten uit één afspraak leveren één bericht op.';

  -- ── GEVAL 2: later nóg een dienst op dezelfde tijd is geen nieuws ─────
  INSERT INTO public.shifts
    (courier_id, shift_type, shift_date, start_time, budgeted_end_time, status, schedule_id)
  VALUES (v_courier, 'regular', v_d3, '07:45', '12:00', 'planned', v_sched) RETURNING id INTO v_s3;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id) VALUES (v_s3, v_pharm);

  PERFORM public.mail_sweep();

  SELECT count(*) INTO v_mails FROM public.mail_outbox
   WHERE subject_id = v_sched AND courier_id = v_courier;
  IF v_mails <> 1 THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: een extra dienst op dezelfde tijd leverde een tweede bericht op (nu %).', v_mails;
  END IF;
  RAISE NOTICE 'GEVAL 2 geslaagd: dezelfde afspraak nog eens bevestigen is geen nieuws.';

  -- ── GEVAL 3: een nieuwe variant erbij is wél nieuws ───────────────────
  UPDATE public.shifts SET start_time = '08:15' WHERE id = v_s3;

  SELECT dirtied_at INTO v_dirty FROM public.courier_announcements
   WHERE subject_id = v_sched AND courier_id = v_courier AND superseded_at IS NULL;
  IF v_dirty IS NULL THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: de trigger zette dirtied_at niet bij een tijdswijziging.';
  END IF;

  PERFORM public.mail_sweep();

  SELECT count(*) INTO v_mails FROM public.mail_outbox
   WHERE subject_id = v_sched AND courier_id = v_courier;
  IF v_mails <> 2 THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: nieuwe variant gaf % berichten, verwacht 2.', v_mails;
  END IF;

  SELECT covered_variants INTO v_cov FROM public.courier_announcements
   WHERE subject_id = v_sched AND courier_id = v_courier AND superseded_at IS NULL;
  IF array_length(v_cov, 1) <> 2 THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: aankondiging dekt % varianten, verwacht 2 (07:45 en 08:15).', array_length(v_cov, 1);
  END IF;
  RAISE NOTICE 'GEVAL 3 geslaagd: een variant erbij levert een bericht op en wordt gedekt.';

  -- ── GEVAL 4: een variant die VERDWIJNT door een ingreep ───────────────
  -- Het spiegelbeeld: 08:15 terugzetten naar 07:45. V wordt {07:45} en is dus
  -- een deelverzameling van C — zonder dirtied_at zou de sweep hier zwijgen,
  -- terwijl de koerier verteld is dat hij om 08:15 komt.
  v_before := v_mails;
  UPDATE public.shifts SET start_time = '07:45' WHERE id = v_s3;
  PERFORM public.mail_sweep();

  SELECT count(*) INTO v_mails FROM public.mail_outbox
   WHERE subject_id = v_sched AND courier_id = v_courier;
  IF v_mails <> v_before + 1 THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: weggewijzigde variant leverde geen bericht op (nog steeds %).', v_mails;
  END IF;

  SELECT covered_variants INTO v_cov FROM public.courier_announcements
   WHERE subject_id = v_sched AND courier_id = v_courier AND superseded_at IS NULL;
  IF array_length(v_cov, 1) <> 1 THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: aankondiging dekt nog % varianten, verwacht 1.', array_length(v_cov, 1);
  END IF;
  RAISE NOTICE 'GEVAL 4 geslaagd: een weggewijzigde variant is nieuws (dank zij dirtied_at).';

  -- ── GEVAL 5: versmallen zonder ingreep is stil ────────────────────────
  -- Nabootsen wat de klok doet: we zetten de aankondiging kunstmatig op twee
  -- varianten zonder vlag. De sweep hoort dan te versmallen en te zwijgen.
  v_before := v_mails;
  UPDATE public.courier_announcements
     SET covered_variants = covered_variants || 'dow9|23:59|-|bike|zzz'::TEXT,
         dirtied_at = NULL
   WHERE subject_id = v_sched AND courier_id = v_courier AND superseded_at IS NULL;

  PERFORM public.mail_sweep();

  SELECT count(*) INTO v_mails FROM public.mail_outbox
   WHERE subject_id = v_sched AND courier_id = v_courier;
  IF v_mails <> v_before THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: versmallen zonder ingreep leverde een bericht op (% i.p.v. %).', v_mails, v_before;
  END IF;

  SELECT covered_variants INTO v_cov FROM public.courier_announcements
   WHERE subject_id = v_sched AND courier_id = v_courier AND superseded_at IS NULL;
  IF 'dow9|23:59|-|bike|zzz' = ANY (v_cov) THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: de verdwenen variant is niet uit covered_variants gehaald.';
  END IF;
  RAISE NOTICE 'GEVAL 5 geslaagd: versmallen door tijdsverloop is stil en ruimt op.';

  -- ── GEVAL 6: losse dienst heeft zijn eigen subject ────────────────────
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, status)
  VALUES (v_courier, 'urgent', v_d1, '19:00', 'planned') RETURNING id INTO v_los;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id) VALUES (v_los, v_pharm);

  PERFORM public.mail_sweep();

  IF NOT EXISTS (SELECT 1 FROM public.mail_outbox
                  WHERE subject_id = v_los AND subject_type = 'shift' AND kind = 'shift_confirmed') THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: losse dienst leverde geen eigen shift_confirmed op.';
  END IF;
  RAISE NOTICE 'GEVAL 6 geslaagd: een losse dienst is zijn eigen subject.';

  -- ── GEVAL 7: verwijderen levert een afmelding met kopie ───────────────
  DELETE FROM public.shifts WHERE id = v_los;

  SELECT payload INTO v_payload FROM public.mail_outbox
   WHERE kind = 'shift_cancelled' AND courier_id = v_courier AND subject_id = v_los;
  IF v_payload IS NULL THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: verwijderen leverde geen afmelding op.';
  END IF;
  IF v_payload->>'start_time' <> '19:00' THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: afmelding mist de starttijd (payload: %).', v_payload;
  END IF;
  IF jsonb_array_length(v_payload->'pharmacies') = 0 THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: apotheeknamen niet gekopieerd — de trigger draait te laat (AFTER i.p.v. BEFORE DELETE).';
  END IF;
  RAISE NOTICE 'GEVAL 7 geslaagd: afmelding bevat de gekopieerde gegevens van de verwijderde dienst.';

  -- ── GEVAL 8: koerierwissel meldt de OUDE koerier af ───────────────────
  IF v_courier2 IS NULL THEN
    RAISE WARNING 'GEVAL 8 OVERGESLAGEN: er is maar één koerier in user_profiles.';
  ELSE
    UPDATE public.shifts SET courier_id = v_courier2 WHERE id = v_s1;

    IF NOT EXISTS (SELECT 1 FROM public.mail_outbox
                    WHERE kind = 'shift_cancelled' AND courier_id = v_courier
                      AND payload->>'reason' = 'andere koerier') THEN
      RAISE EXCEPTION 'GEVAL 8 GEFAALD: koerierwissel leverde geen afmelding voor de oude koerier op.';
    END IF;
    RAISE NOTICE 'GEVAL 8 geslaagd: bij een wissel wordt de oude koerier afgemeld.';
  END IF;

  -- ── GEVAL 9: sweep is idempotent ──────────────────────────────────────
  PERFORM public.mail_sweep();
  SELECT count(*) INTO v_before FROM public.mail_outbox WHERE courier_id IN (v_courier, v_courier2);
  PERFORM public.mail_sweep();
  SELECT count(*) INTO v_mails FROM public.mail_outbox WHERE courier_id IN (v_courier, v_courier2);
  IF v_mails <> v_before THEN
    RAISE EXCEPTION 'GEVAL 9 GEFAALD: een tweede sweep zonder wijzigingen leverde % extra bericht(en) op.', v_mails - v_before;
  END IF;
  RAISE NOTICE 'GEVAL 9 geslaagd: een sweep zonder wijzigingen doet niets.';

  -- ── GEVAL 10: ingreep die per saldo niets verandert ───────────────────
  -- Aanpassen en terugzetten binnen één sweep-interval: de vlag staat, maar
  -- V = C. Er hoort geen bericht uit te gaan, én de vlag moet gewist worden —
  -- anders wordt de eerstvolgende versmalling door tijdsverloop als ingreep
  -- gelezen en gaat er alsnog een bericht uit.
  SELECT count(*) INTO v_before FROM public.mail_outbox
   WHERE subject_id = v_sched AND courier_id = v_courier;

  UPDATE public.shifts SET start_time = '09:00' WHERE id = v_s2;
  UPDATE public.shifts SET start_time = '07:45' WHERE id = v_s2;

  SELECT dirtied_at INTO v_dirty FROM public.courier_announcements
   WHERE subject_id = v_sched AND courier_id = v_courier AND superseded_at IS NULL;
  IF v_dirty IS NULL THEN
    RAISE EXCEPTION 'GEVAL 10 ONBRUIKBAAR: de vlag staat niet, dus er valt niets te toetsen.';
  END IF;

  PERFORM public.mail_sweep();

  SELECT count(*) INTO v_mails FROM public.mail_outbox
   WHERE subject_id = v_sched AND courier_id = v_courier;
  IF v_mails <> v_before THEN
    RAISE EXCEPTION 'GEVAL 10 GEFAALD: aanpassen-en-terugzetten leverde een bericht op (% i.p.v. %).', v_mails, v_before;
  END IF;

  SELECT dirtied_at INTO v_dirty FROM public.courier_announcements
   WHERE subject_id = v_sched AND courier_id = v_courier AND superseded_at IS NULL;
  IF v_dirty IS NOT NULL THEN
    RAISE EXCEPTION 'GEVAL 10 GEFAALD: de vlag staat na de sweep nog steeds — elke volgende versmalling wordt dan als ingreep gelezen.';
  END IF;
  RAISE NOTICE 'GEVAL 10 geslaagd: geen bericht, en de vlag is gewist.';

  RAISE NOTICE 'ALLE GEVALLEN GESLAAGD — de ROLLBACK hierna draait de testdata terug.';
END;
$$;

ROLLBACK;
