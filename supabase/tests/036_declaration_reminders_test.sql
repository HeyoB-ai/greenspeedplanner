-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 036: herinneringen voor openstaande declaraties
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai migratie 036 eerst (of proefdraai 036 met ROLLBACK en daarna dit).
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Er blijft niets staan: één transactie die op ROLLBACK eindigt.
--
-- ⚠ DE PROEFDIENST STAAT OP VANDAAG, NIET IN HET VERLEDEN
--   Op public.shifts zit een trigger shifts_no_past_insert() die een INSERT met
--   een datum in het verleden weigert ("Een dienst kan niet op een datum in het
--   verleden worden ingepland"). Die trigger staat in geen enkele migratie — hij
--   is rechtstreeks in de database aangemaakt.
--
--   Er omheen werken zou de test waardeloos maken, en het is ook niet nodig: in
--   de praktijk BESTAAT een afgelopen dienst nooit als INSERT. Hij wordt vooruit
--   ingepland en wordt daarna vanzelf verleden tijd; declaration_sweep() kijkt
--   met declaration_shift_end(...) < now() naar rijen die er al stonden. Een
--   dienst van vandaag is dus de eerlijke nabootsing.
--
--   Deze test heeft niet nodig dat de dienst al is afgelopen — hij gaat over de
--   instellingen, de berichtsoort en de logtabel. Alleen de vervaldatum wordt
--   uit de dienstdatum afgeleid, en die moet met de invoer kloppen.
--
-- De test meet in VERSCHILLEN ten opzichte van de beginstand. De database is
-- gedeeld en er staan al declaraties en berichten in; een test die absolute
-- getallen verwacht zou morgen falen zonder dat er iets stuk is.
--
-- WAT DE TEST DEKT
--   1. De twee termijnen staan op 5 en 4, en 4 ≤ 5 — de kern van de migratie
--   2. mail_outbox neemt 'declaration_reminder' aan en weigert nog steeds onzin
--   3. De primary key is de idempotentie: een tweede claim levert nul rijen
--   4. stage 3 bestaat niet — de bovengrens van twee is een schemagarantie
--   5. declaration_expire_stale() ruimt een oude herinnering op en laat een
--      verse staan
--   6. declaration_release() zet een geclaimde herinnering terug op 'pending'
--   7. Zonder shift_date in de payload verloopt een herinnering NOOIT — de
--      afhankelijkheid uit punt 5 van de migratie, hier vastgepind zodat een
--      latere wijziging hem niet stilletjes breekt
--   8. Geen enkele openstaande declaratie heeft nog een vervaldatum voorbij
--      dienstdatum + token_valid_days — punt 1b heeft ze allemaal ingekort
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
  v_courier   UUID;
  v_home      TEXT;
  v_shift     UUID;
  v_dec       UUID;
  v_cfg       public.declaration_settings;
  v_out_old   UUID;
  v_out_new   UUID;
  v_out_nodat UUID;
  v_n         INT;
  v_status    TEXT;
  -- Vandaag, niet gisteren: zie de toelichting bovenaan over shifts_no_past_insert().
  v_day       DATE := current_date;
BEGIN
  -- ── Opzet ──────────────────────────────────────────────────────────────
  -- De instellingen eerst: de proefdeclaratie hieronder moet dezelfde termijn
  -- krijgen als alles wat punt 1b heeft ingekort, anders zou geval 8 op zijn
  -- eigen fixture struikelen.
  SELECT * INTO v_cfg FROM public.declaration_settings WHERE id;

  SELECT id INTO v_courier FROM public.user_profiles WHERE role = 'courier' ORDER BY id LIMIT 1;
  IF v_courier IS NULL THEN RAISE EXCEPTION 'OPZET: geen koerier in user_profiles.'; END IF;
  SELECT id INTO v_home FROM public.pharmacies ORDER BY id LIMIT 1;
  IF v_home IS NULL THEN RAISE EXCEPTION 'OPZET: geen apotheek in pharmacies.'; END IF;

  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time,
                             budgeted_end_time, status, transport_mode)
  VALUES (v_courier, 'regular', v_day, '08:00', '12:00', 'planned', 'bike')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id) VALUES (v_shift, v_home);

  INSERT INTO public.shift_declarations (shift_id, courier_id, token_hash, token_expires_at)
  VALUES (v_shift, v_courier,
          public.declaration_hash_token(public.declaration_new_token()),
          (v_day + v_cfg.token_valid_days)::TIMESTAMP AT TIME ZONE 'Europe/Amsterdam')
  RETURNING id INTO v_dec;

  -- ── 1. De twee termijnen ───────────────────────────────────────────────
  IF v_cfg.token_valid_days <> 5 THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: token_valid_days is %, verwacht 5.', v_cfg.token_valid_days;
  END IF;
  IF v_cfg.max_age_days <> 4 THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: max_age_days is %, verwacht 4.', v_cfg.max_age_days;
  END IF;
  -- De eigenlijke eis. De getallen mogen later veranderen; deze verhouding niet,
  -- want anders ontstaat het venster waarin een bericht nog mag maar de link al
  -- dood is — negen dagen foutregels zonder dat er iets uitgaat.
  IF v_cfg.max_age_days > v_cfg.token_valid_days THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: max_age_days (%) > token_valid_days (%). '
                    'Een nabericht mag dan nog uit terwijl de invullink al verlopen is.',
                    v_cfg.max_age_days, v_cfg.token_valid_days;
  END IF;

  -- ── 2. De nieuwe berichtsoort ──────────────────────────────────────────
  INSERT INTO public.mail_outbox (courier_id, kind, subject_type, subject_id, payload)
  VALUES (v_courier, 'declaration_reminder', 'shift', v_shift,
          jsonb_build_object('declaration_id', v_dec,
                             'shift_date', v_day::TEXT))
  RETURNING id INTO v_out_new;

  IF v_out_new IS NULL THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: mail_outbox nam een declaration_reminder niet aan.';
  END IF;

  -- En de constraint moet nog steeds iets tegenhouden, anders is hij per ongeluk
  -- verruimd tot "alles mag".
  BEGIN
    INSERT INTO public.mail_outbox (courier_id, kind, payload)
    VALUES (v_courier, 'geen_bestaande_soort', '{}'::jsonb);
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: een onbekende berichtsoort werd geaccepteerd.';
  EXCEPTION WHEN check_violation THEN
    NULL;  -- goed zo
  END;

  -- ── 3. De primary key is de idempotentie ───────────────────────────────
  INSERT INTO public.declaration_reminders (declaration_id, stage) VALUES (v_dec, 1);

  INSERT INTO public.declaration_reminders (declaration_id, stage)
  VALUES (v_dec, 1) ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: een tweede claim op dezelfde stap leverde % rij(en) op, '
                    'verwacht 0 — de idempotentie werkt niet.', v_n;
  END IF;

  -- De tweede stap is wél een eigen claim; anders zou de tabel hetzelfde doen
  -- als shift_sms_log en kan er nooit een tweede herinnering uit.
  INSERT INTO public.declaration_reminders (declaration_id, stage)
  VALUES (v_dec, 2) ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: stap 2 kon niet geclaimd worden (% rijen).', v_n;
  END IF;

  SELECT count(*) INTO v_n FROM public.declaration_reminders WHERE declaration_id = v_dec;
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: % herinneringen voor één declaratie, verwacht 2.', v_n;
  END IF;

  -- ── 4. Er is geen derde stap ───────────────────────────────────────────
  BEGIN
    INSERT INTO public.declaration_reminders (declaration_id, stage) VALUES (v_dec, 3);
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: stage 3 werd geaccepteerd — "nooit meer dan twee" '
                    'is geen schemagarantie.';
  EXCEPTION WHEN check_violation THEN
    NULL;  -- goed zo
  END;

  -- ── 5. De leeftijdscontrole kent de nieuwe soort ───────────────────────
  -- Een herinnering over een dienst van ruim vóór max_age_days (4), plus de
  -- verse van geval 2 die moet blijven staan.
  INSERT INTO public.mail_outbox (courier_id, kind, subject_type, subject_id, payload)
  VALUES (v_courier, 'declaration_reminder', 'shift', v_shift,
          jsonb_build_object('declaration_id', v_dec,
                             'shift_date', (current_date - 30)::TEXT))
  RETURNING id INTO v_out_old;

  PERFORM public.declaration_expire_stale();

  SELECT status INTO v_status FROM public.mail_outbox WHERE id = v_out_old;
  IF v_status <> 'expired' THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: een herinnering over een dienst van 30 dagen terug staat '
                    'op %, verwacht expired — hij blijft dus eeuwig in de wachtrij.', v_status;
  END IF;

  SELECT status INTO v_status FROM public.mail_outbox WHERE id = v_out_new;
  IF v_status <> 'pending' THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: een herinnering van vandaag staat op %, verwacht pending — '
                    'de leeftijdscontrole ruimt te veel op.', v_status;
  END IF;

  -- ── 6. Terugzetten na een mislukte claim ───────────────────────────────
  UPDATE public.mail_outbox SET status = 'sending', claimed_at = now() WHERE id = v_out_new;

  SELECT public.declaration_release(ARRAY[v_out_new]) INTO v_n;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: declaration_release gaf % terug, verwacht 1 — een '
                    'geclaimde herinnering blijft dus op sending staan.', v_n;
  END IF;

  SELECT status INTO v_status FROM public.mail_outbox WHERE id = v_out_new;
  IF v_status <> 'pending' THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: status na release is %, verwacht pending.', v_status;
  END IF;

  -- ── 7. Zonder shift_date verloopt een herinnering nooit ────────────────
  -- Geen wenselijk gedrag maar een gevolg van de vergelijking in
  -- declaration_expire_stale(): (payload->>'shift_date')::DATE is dan NULL, en
  -- NULL < iets is niet waar. Hier vastgepind zodat de eis zichtbaar blijft:
  -- elke herinneringsrij MOET shift_date in zijn payload hebben.
  INSERT INTO public.mail_outbox (courier_id, kind, subject_type, subject_id, payload)
  VALUES (v_courier, 'declaration_reminder', 'shift', v_shift,
          jsonb_build_object('declaration_id', v_dec))
  RETURNING id INTO v_out_nodat;

  PERFORM public.declaration_expire_stale();

  SELECT status INTO v_status FROM public.mail_outbox WHERE id = v_out_nodat;
  IF v_status <> 'pending' THEN
    RAISE EXCEPTION 'GEVAL 7: een herinnering zonder shift_date staat op % in plaats van pending. '
                    'Gedrag gewijzigd — controleer of de verzendkant nog klopt.', v_status;
  END IF;

  -- ── 8. Punt 1b heeft alles ingekort ────────────────────────────────────
  -- Geen enkele declaratie waar nog iets in te vullen valt mag een link hebben
  -- die langer meegaat dan de nieuwe termijn. Zou er één overblijven, dan staan
  -- er twee termijnen naast elkaar en klopt geen enkele uitspraak over "de
  -- termijn" meer — precies wat punt 1b moest wegnemen.
  SELECT count(*) INTO v_n
  FROM public.shift_declarations d
  JOIN public.shifts s ON s.id = d.shift_id
  WHERE d.status IN ('open', 'submitted')
    AND d.token_expires_at >
        ((s.shift_date + v_cfg.token_valid_days)::TIMESTAMP AT TIME ZONE 'Europe/Amsterdam');

  IF v_n <> 0 THEN
    RAISE EXCEPTION 'GEVAL 8 GEFAALD: % declaratie(s) hebben nog een link voorbij '
                    'dienstdatum + % dagen — punt 1b heeft ze niet allemaal geraakt.',
                    v_n, v_cfg.token_valid_days;
  END IF;

  RAISE NOTICE 'Alle 8 gevallen geslaagd.';
END $$;

-- ────────────────────────────────────────────────────────────────────────
-- Stand na afloop, ter controle vóór de rollback.
-- ────────────────────────────────────────────────────────────────────────
SELECT token_valid_days, max_age_days FROM public.declaration_settings;

ROLLBACK;   -- er blijft niets van deze test achter
