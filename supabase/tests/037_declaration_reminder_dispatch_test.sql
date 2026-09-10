-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 037: wie krijgt een herinnering, en het claimen ervan
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 036 en 037 eerst (of proefdraai ze met ROLLBACK en daarna dit).
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: één transactie die op ROLLBACK eindigt. Dat geldt ook
-- voor de DELETE op courier_contacts in geval 6 en voor de instelling die hieronder
-- tijdelijk wordt bijgezet — allebei rollen ze gewoon mee terug.
--
-- ⚠ DE DIENSTEN STAAN OP VANDAAG, EN DE TERMIJN GAAT OMLAAG
--   Op public.shifts zit een trigger shifts_no_past_insert() die een INSERT met
--   een datum in het verleden weigert. Die trigger staat in geen enkele migratie —
--   hij is rechtstreeks in de database aangemaakt.
--
--   Er omheen werken zou de test waardeloos maken. Het is ook niet nodig: in de
--   praktijk BESTAAT een afgelopen dienst nooit als INSERT. Hij wordt vooruit
--   ingepland en wordt daarna vanzelf verleden tijd. Deze test bootst dat na met
--   diensten van VANDAAG die vroeg op de dag al zijn afgelopen.
--
--   Maar stage 1 valt op "afloop + de helft van expected_within_hours", en met de
--   standaard van 48 uur ligt dat morgen. Daarom zet de test expected_within_hours
--   tijdelijk op 1 uur: dan is stage 1 een half uur na afloop opeisbaar en past het
--   binnen dezelfde dag. Dat is geen omweg maar precies wat migratie 037 belooft —
--   dat de momenten uit de database komen en niet uit een getal in code. Zou dat
--   niet zo zijn, dan faalt deze test. Migratie 019 en 021 doen in hun tests
--   hetzelfde met deze tabel.
--
--   GEVOLG: draai deze test NIET tussen 00:00 en 01:00 Nederlandse tijd. Dan zijn
--   de momenten van vandaag nog niet verstreken en klopt de opzet niet. De test
--   stopt in dat geval met een duidelijke melding in plaats van te falen.
--
-- OPSTELLING — vier declaraties, elk voor een eigen dienst van vandaag:
--   A  open,      dienst 00:00-00:05, verloopt over 3 dagen  → alleen stage 1
--   B  open,      dienst 00:05-00:10, verloopt over 12 uur   → beide, dus stage 2
--   C  submitted, dienst 00:10-00:15                         → mag niet mee
--   D  open,      dienst 00:15-00:20, token al verlopen      → mag niet mee
--
-- WAT DE TEST DEKT
--   1. Een openstaande declaratie waarvan het moment voorbij is komt terug,
--      met stage 1
--   2. 'submitted' en een verlopen token komen niet terug
--   3. Zijn beide momenten voorbij, dan komt alleen de HOOGSTE stap terug
--   4. Claimen legt een rij vast én zet de mail klaar, met shift_date en
--      expires_at in de payload — zonder shift_date verloopt die rij nooit
--   5. Een tweede claim op dezelfde stap geeft false
--   6. Een koerier zonder telefoonnummer valt NIET weg maar komt terug met
--      phone_e164 NULL — de LEFT JOIN, niet de inner join van sms_due_shifts()
--   7. record() legt de uitkomst vast
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
  v_courier UUID;
  v_home    TEXT;
  v_sa      UUID; v_sb UUID; v_sc UUID; v_sd UUID;
  v_da      UUID; v_db UUID; v_dc UUID; v_dd UUID;
  v_stage   SMALLINT;
  v_ok      BOOLEAN;
  v_n       INT;
  v_row     RECORD;
  v_payload JSONB;
  -- Vandaag, niet in het verleden: zie de toelichting bovenaan.
  v_day     DATE := current_date;
BEGIN
  -- De momenten van vandaag moeten verstreken zijn, anders meet de test niets.
  IF (now() AT TIME ZONE 'Europe/Amsterdam')::TIME < TIME '01:00' THEN
    RAISE EXCEPTION 'OPZET: het is nu % in Nederland. Deze test heeft diensten van '
                    'vroeg vandaag nodig die al zijn afgelopen; draai hem na 01:00.',
                    to_char((now() AT TIME ZONE 'Europe/Amsterdam')::TIME, 'HH24:MI');
  END IF;

  -- De termijn tijdelijk naar 1 uur, zodat stage 1 een half uur na afloop
  -- opeisbaar is in plaats van over 24 uur. Rolt mee terug met de transactie.
  UPDATE public.declaration_settings SET expected_within_hours = 1 WHERE id;

  -- ── Opzet ──────────────────────────────────────────────────────────────
  SELECT id INTO v_courier FROM public.user_profiles WHERE role = 'courier' ORDER BY id LIMIT 1;
  IF v_courier IS NULL THEN RAISE EXCEPTION 'OPZET: geen koerier in user_profiles.'; END IF;
  SELECT id INTO v_home FROM public.pharmacies ORDER BY id LIMIT 1;
  IF v_home IS NULL THEN RAISE EXCEPTION 'OPZET: geen apotheek in pharmacies.'; END IF;

  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time,
                             budgeted_end_time, status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '00:00', '00:05', 'planned', 'bike')
  RETURNING id INTO v_sa;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id) VALUES (v_sa, v_home);

  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time,
                             budgeted_end_time, status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '00:05', '00:10', 'planned', 'bike')
  RETURNING id INTO v_sb;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id) VALUES (v_sb, v_home);

  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time,
                             budgeted_end_time, status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '00:10', '00:15', 'planned', 'bike')
  RETURNING id INTO v_sc;

  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time,
                             budgeted_end_time, status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '00:15', '00:20', 'planned', 'bike')
  RETURNING id INTO v_sd;

  -- De vervaldatums worden hier expliciet gezet en niet uit de instelling
  -- afgeleid: de test gaat over de MOMENTEN, en die moeten stuurbaar zijn zonder
  -- dat een gewijzigde token_valid_days hem laat kantelen.
  INSERT INTO public.shift_declarations (shift_id, courier_id, token_hash, token_expires_at, status)
  VALUES (v_sa, v_courier, public.declaration_hash_token(public.declaration_new_token()),
          now() + INTERVAL '3 days', 'open')
  RETURNING id INTO v_da;

  INSERT INTO public.shift_declarations (shift_id, courier_id, token_hash, token_expires_at, status)
  VALUES (v_sb, v_courier, public.declaration_hash_token(public.declaration_new_token()),
          now() + INTERVAL '12 hours', 'open')
  RETURNING id INTO v_db;

  INSERT INTO public.shift_declarations (shift_id, courier_id, token_hash, token_expires_at, status)
  VALUES (v_sc, v_courier, public.declaration_hash_token(public.declaration_new_token()),
          now() + INTERVAL '3 days', 'submitted')
  RETURNING id INTO v_dc;

  INSERT INTO public.shift_declarations (shift_id, courier_id, token_hash, token_expires_at, status)
  VALUES (v_sd, v_courier, public.declaration_hash_token(public.declaration_new_token()),
          now() - INTERVAL '1 day', 'open')
  RETURNING id INTO v_dd;

  -- ── 1. A komt terug met stage 1 ────────────────────────────────────────
  SELECT stage INTO v_stage
  FROM public.declaration_reminder_due()
  WHERE declaration_id = v_da;

  IF v_stage IS NULL THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: declaratie A komt niet terug, terwijl haar eerste '
                    'moment voorbij is.';
  END IF;
  IF v_stage <> 1 THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: declaratie A komt terug met stage %, verwacht 1.', v_stage;
  END IF;

  -- ── 2. C en D komen niet terug ─────────────────────────────────────────
  SELECT count(*) INTO v_n
  FROM public.declaration_reminder_due()
  WHERE declaration_id = v_dc;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: een declaratie met status submitted wordt herinnerd.';
  END IF;

  SELECT count(*) INTO v_n
  FROM public.declaration_reminder_due()
  WHERE declaration_id = v_dd;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: een declaratie met een verlopen token wordt herinnerd — '
                    'een herinnering voor een dode link.';
  END IF;

  -- ── 3. Beide momenten voorbij → alleen de hoogste stap ─────────────────
  SELECT count(*) INTO v_n
  FROM public.declaration_reminder_due()
  WHERE declaration_id = v_db;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: declaratie B levert % rijen op, verwacht 1 — er gaan '
                    'twee berichten in dezelfde run uit.', v_n;
  END IF;

  SELECT stage INTO v_stage
  FROM public.declaration_reminder_due()
  WHERE declaration_id = v_db;
  IF v_stage <> 2 THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: declaratie B komt terug met stage %, verwacht 2 — de '
                    'hoogste opeisbare stap hoort te winnen.', v_stage;
  END IF;

  -- ── 4. Claimen legt vast én zet de mail klaar ──────────────────────────
  SELECT public.declaration_reminder_claim(v_da, 1::SMALLINT) INTO v_ok;
  IF v_ok IS NOT TRUE THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: de eerste claim gaf % in plaats van true.', v_ok;
  END IF;

  SELECT * INTO v_row FROM public.declaration_reminders
  WHERE declaration_id = v_da AND stage = 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: er staat geen logrij na het claimen.';
  END IF;
  IF v_row.status <> 'sending' THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: status na claimen is %, verwacht sending.', v_row.status;
  END IF;

  SELECT payload INTO v_payload FROM public.mail_outbox
  WHERE kind = 'declaration_reminder' AND subject_id = v_sa
  ORDER BY created_at DESC LIMIT 1;
  IF v_payload IS NULL THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: het claimen heeft geen mail in de outbox gezet.';
  END IF;
  -- Zonder shift_date verloopt deze rij NOOIT: declaration_expire_stale()
  -- vergelijkt op (payload->>'shift_date')::DATE en NULL valt buiten elke
  -- vergelijking. Dat is de reden dat de payload hier in SQL wordt opgebouwd.
  IF v_payload->>'shift_date' IS NULL THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: shift_date ontbreekt in de payload — die rij zou '
                    'eeuwig in de wachtrij blijven staan.';
  END IF;
  IF v_payload->>'expires_at' IS NULL THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: expires_at ontbreekt in de payload — de mail kan dan '
                    'geen datum noemen en valt terug op geen inhoud.';
  END IF;
  IF (v_payload->>'stage')::INT <> 1 THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: stage in de payload is %, verwacht 1.', v_payload->>'stage';
  END IF;

  -- En A hoort nu niet meer als stage 1 terug te komen.
  SELECT count(*) INTO v_n
  FROM public.declaration_reminder_due()
  WHERE declaration_id = v_da AND stage = 1;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: A komt na het claimen opnieuw als stage 1 terug.';
  END IF;

  -- ── 5. Tweede claim op dezelfde stap ───────────────────────────────────
  SELECT public.declaration_reminder_claim(v_da, 1::SMALLINT) INTO v_ok;
  IF v_ok IS NOT FALSE THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: een tweede claim gaf % in plaats van false — de '
                    'idempotentie werkt niet.', v_ok;
  END IF;

  SELECT count(*) INTO v_n FROM public.mail_outbox
  WHERE kind = 'declaration_reminder' AND subject_id = v_sa;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: % mails voor dezelfde stap, verwacht 1.', v_n;
  END IF;

  -- ── 6. Zonder nummer valt de koerier niet weg ──────────────────────────
  -- De DELETE rolt mee terug met de transactie. Zou hier een INNER JOIN staan,
  -- zoals in sms_due_shifts() (migratie 012), dan verdween deze koerier
  -- stilzwijgend uit de selectie en zag niemand dat er een nummer ontbreekt.
  DELETE FROM public.courier_contacts WHERE courier_id = v_courier;

  SELECT count(*) INTO v_n
  FROM public.declaration_reminder_due()
  WHERE declaration_id = v_db;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: een koerier zonder telefoonnummer verdwijnt uit de '
                    'selectie (% rijen voor B) — een ontbrekend nummer hoort gemeld te '
                    'worden, niet verzwegen.', v_n;
  END IF;

  SELECT phone_e164 INTO v_row
  FROM public.declaration_reminder_due()
  WHERE declaration_id = v_db;
  IF v_row.phone_e164 IS NOT NULL THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: phone_e164 is niet NULL terwijl er geen contactrij is.';
  END IF;

  -- ── 7. De uitkomst vastleggen ──────────────────────────────────────────
  PERFORM public.declaration_reminder_record(
    v_da, 1::SMALLINT, true, 'brevo-123', NULL);

  SELECT * INTO v_row FROM public.declaration_reminders
  WHERE declaration_id = v_da AND stage = 1;
  IF v_row.status <> 'sent' THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: status na een geslaagde SMS is %, verwacht sent.', v_row.status;
  END IF;
  IF v_row.sent_at IS NULL THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: sent_at is niet gevuld na een geslaagde SMS.';
  END IF;
  IF v_row.provider_message_id <> 'brevo-123' THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: provider_message_id is %, verwacht brevo-123.',
                    v_row.provider_message_id;
  END IF;

  -- En de mislukte kant: dit is óók het geval "geen telefoonnummer".
  PERFORM public.declaration_reminder_claim(v_db, 2::SMALLINT);
  PERFORM public.declaration_reminder_record(
    v_db, 2::SMALLINT, false, NULL, 'geen telefoonnummer bij deze koerier');

  SELECT * INTO v_row FROM public.declaration_reminders
  WHERE declaration_id = v_db AND stage = 2;
  IF v_row.status <> 'failed' THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: status na een mislukte SMS is %, verwacht failed.', v_row.status;
  END IF;
  IF v_row.sent_at IS NOT NULL THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: sent_at is gevuld terwijl er niets is verstuurd.';
  END IF;
  IF v_row.error IS NULL THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: de reden ontbreekt bij een mislukte herinnering.';
  END IF;

  -- Ook bij een mislukte SMS is de mail wél ingeschreven: het nummer ontbreekt,
  -- de koerier niet.
  SELECT count(*) INTO v_n FROM public.mail_outbox
  WHERE kind = 'declaration_reminder' AND subject_id = v_sb;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: % mail(s) voor B, verwacht 1 — een ontbrekend nummer '
                    'mag de mail niet tegenhouden.', v_n;
  END IF;

  -- En B is nu helemaal klaar: geen enkele stap staat meer open.
  SELECT count(*) INTO v_n
  FROM public.declaration_reminder_due()
  WHERE declaration_id = v_db;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: B komt na twee stappen nog terug — er kan een derde uit.';
  END IF;

  RAISE NOTICE 'Alle 7 gevallen geslaagd.';
END $$;

-- ────────────────────────────────────────────────────────────────────────
-- Stand na afloop, ter controle vóór de rollback.
-- ────────────────────────────────────────────────────────────────────────
SELECT * FROM public.declaration_reminder_due() ORDER BY due_at;

ROLLBACK;   -- er blijft niets van deze test achter
