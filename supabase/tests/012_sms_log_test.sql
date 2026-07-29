-- ════════════════════════════════════════════════════════════════════════
-- TEST — migratie 012: selectie en idempotentie van de herinnerings-SMS
-- ════════════════════════════════════════════════════════════════════════
-- Plak dit hele bestand in de Supabase SQL Editor en draai het in één keer.
-- Draai 011 en 012 eerst.
--
-- UITKOMST
--   Geen foutmelding  → alle gevallen geslaagd.
--   Wel een melding   → GEFAALD; de tekst noemt het geval en wat er misging.
--
-- Alles zit in één transactie die op ROLLBACK eindigt: er blijft niets staan en
-- er gaat niets de deur uit (de test raakt Brevo niet — die stap zit in de Edge
-- Function, niet in de database).
--
-- WAT DE TEST DEKT
--   1. Koerier zonder nummer            → dienst komt NIET in de selectie
--   2. Nummer erbij                     → dienst komt WEL in de selectie, met
--                                          apotheeknaam en juiste starttijd
--   3. Concept ('draft')                → NOOIT in de selectie
--   4. Dienst die al begonnen is        → NIET meer in de selectie
--   5. Dienst buiten het venster (24u30)→ NIET in de selectie  (tijdzonetoets:
--      de fixtures staan op lokale wandklok; ontbreekt de AT TIME ZONE-omrekening
--      in sms_due_shifts, dan schuift de grens een uur en valt geval 2 of 5 om)
--   6. sms_claim_shift                  → eerste keer true, tweede keer false
--   7. Na de claim                      → dienst verdwijnt uit de selectie
--   8. sms_record_result                → status 'sent' + sent_at gevuld
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
  v_courier   UUID;
  v_pharmacy  TEXT;
  v_pname     TEXT;
  -- Lokale wandklok: precies de eenheid waarin shift_date + start_time staan.
  v_local_now TIMESTAMP := (now() AT TIME ZONE 'Europe/Amsterdam');
  v_soon      TIMESTAMP := (now() AT TIME ZONE 'Europe/Amsterdam') + interval '23 hours 30 minutes';
  v_late      TIMESTAMP := (now() AT TIME ZONE 'Europe/Amsterdam') + interval '24 hours 30 minutes';
  v_past      TIMESTAMP := (now() AT TIME ZONE 'Europe/Amsterdam') - interval '1 hour';
  v_shift     UUID;
  v_draft     UUID;
  v_late_id   UUID;
  v_past_id   UUID;
  v_row       RECORD;
  v_claimed   BOOLEAN;
  v_status    TEXT;
  v_sent_at   TIMESTAMPTZ;
BEGIN
  -- ── Voorbereiding ────────────────────────────────────────────────────
  SELECT id INTO v_courier FROM public.user_profiles WHERE role = 'courier' LIMIT 1;
  IF v_courier IS NULL THEN
    RAISE EXCEPTION 'OPZET: geen koerier in user_profiles — geen dienst toe te wijzen.';
  END IF;

  SELECT id, name INTO v_pharmacy, v_pname FROM public.pharmacies LIMIT 1;
  IF v_pharmacy IS NULL THEN
    RAISE EXCEPTION 'OPZET: geen apotheek in pharmacies.';
  END IF;

  -- Deze koerier heeft mogelijk al een echt nummer; binnen deze transactie
  -- halen we het weg zodat geval 1 het "geen nummer"-pad echt toetst. De
  -- ROLLBACK zet het aan het eind terug.
  DELETE FROM public.courier_contacts WHERE courier_id = v_courier;

  -- Bevestigde dienst, ruim binnen het venster.
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, status)
  VALUES (v_courier, 'regular', v_soon::date, v_soon::time, 'planned')
  RETURNING id INTO v_shift;
  INSERT INTO public.shift_pharmacies (shift_id, pharmacy_id) VALUES (v_shift, v_pharmacy);

  -- ── GEVAL 1: geen nummer → niet in de selectie ───────────────────────
  IF EXISTS (SELECT 1 FROM public.sms_due_shifts(24) d WHERE d.shift_id = v_shift) THEN
    RAISE EXCEPTION 'GEVAL 1 GEFAALD: dienst zonder telefoonnummer staat toch in de selectie.';
  END IF;
  RAISE NOTICE 'GEVAL 1 geslaagd: zonder nummer geen bericht.';

  -- ── GEVAL 2: mét nummer → wel in de selectie, met de juiste gegevens ──
  INSERT INTO public.courier_contacts (courier_id, phone_e164)
  VALUES (v_courier, '+31612345678');

  SELECT * INTO v_row FROM public.sms_due_shifts(24) d WHERE d.shift_id = v_shift;
  IF v_row IS NULL THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: dienst met nummer ontbreekt in de selectie.';
  END IF;
  IF v_row.phone_e164 <> '+31612345678' THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: verkeerd nummer teruggegeven (%).', v_row.phone_e164;
  END IF;
  IF NOT (v_pname = ANY (v_row.pharmacy_names)) THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: apotheeknaam ontbreekt in pharmacy_names (%).', v_row.pharmacy_names;
  END IF;
  -- start_at moet exact het lokale wandklokmoment zijn, terug in UTC gerekend.
  IF v_row.start_at <> (v_soon::date + v_soon::time) AT TIME ZONE 'Europe/Amsterdam' THEN
    RAISE EXCEPTION 'GEVAL 2 GEFAALD: start_at (%) wijkt af van de lokale starttijd.', v_row.start_at;
  END IF;
  RAISE NOTICE 'GEVAL 2 geslaagd: dienst staat in de selectie met nummer, apotheek en juiste starttijd.';

  -- ── GEVAL 3: concept komt er nooit in ────────────────────────────────
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, status)
  VALUES (v_courier, 'regular', v_soon::date, v_soon::time, 'draft')
  RETURNING id INTO v_draft;

  IF EXISTS (SELECT 1 FROM public.sms_due_shifts(24) d WHERE d.shift_id = v_draft) THEN
    RAISE EXCEPTION 'GEVAL 3 GEFAALD: een concept staat in de selectie.';
  END IF;
  RAISE NOTICE 'GEVAL 3 geslaagd: concepten blijven buiten de selectie.';

  -- ── GEVAL 4: al begonnen dienst valt af ──────────────────────────────
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, status)
  VALUES (v_courier, 'regular', v_past::date, v_past::time, 'planned')
  RETURNING id INTO v_past_id;

  IF EXISTS (SELECT 1 FROM public.sms_due_shifts(24) d WHERE d.shift_id = v_past_id) THEN
    RAISE EXCEPTION 'GEVAL 4 GEFAALD: een dienst die al begonnen is staat in de selectie.';
  END IF;
  RAISE NOTICE 'GEVAL 4 geslaagd: begonnen diensten vallen af.';

  -- ── GEVAL 5: buiten het venster (tijdzonetoets) ──────────────────────
  INSERT INTO public.shifts (courier_id, shift_type, shift_date, start_time, status)
  VALUES (v_courier, 'regular', v_late::date, v_late::time, 'planned')
  RETURNING id INTO v_late_id;

  IF EXISTS (SELECT 1 FROM public.sms_due_shifts(24) d WHERE d.shift_id = v_late_id) THEN
    RAISE EXCEPTION 'GEVAL 5 GEFAALD: dienst over 24u30 valt binnen het 24-uursvenster — controleer de AT TIME ZONE-omrekening.';
  END IF;
  RAISE NOTICE 'GEVAL 5 geslaagd: venstergrens klopt op lokale tijd.';

  -- ── GEVAL 6: claimen is precies één keer mogelijk ────────────────────
  SELECT public.sms_claim_shift(v_shift, v_courier, '+31612345678') INTO v_claimed;
  IF v_claimed IS NOT TRUE THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: eerste claim gaf % in plaats van true.', v_claimed;
  END IF;

  SELECT public.sms_claim_shift(v_shift, v_courier, '+31612345678') INTO v_claimed;
  IF v_claimed IS NOT FALSE THEN
    RAISE EXCEPTION 'GEVAL 6 GEFAALD: tweede claim gaf % in plaats van false — dubbele SMS mogelijk.', v_claimed;
  END IF;
  RAISE NOTICE 'GEVAL 6 geslaagd: één claim per dienst, de tweede stuit op de sleutel.';

  -- ── GEVAL 7: geclaimde dienst verdwijnt uit de selectie ──────────────
  IF EXISTS (SELECT 1 FROM public.sms_due_shifts(24) d WHERE d.shift_id = v_shift) THEN
    RAISE EXCEPTION 'GEVAL 7 GEFAALD: geclaimde dienst staat nog in de selectie — een volgende run stuurt opnieuw.';
  END IF;
  RAISE NOTICE 'GEVAL 7 geslaagd: na de claim is de dienst uit de selectie.';

  -- ── GEVAL 8: uitkomst wegschrijven ───────────────────────────────────
  PERFORM public.sms_record_result(v_shift, true, 'test-message-id', NULL);
  SELECT status, sent_at INTO v_status, v_sent_at
  FROM public.shift_sms_log WHERE shift_id = v_shift;

  IF v_status <> 'sent' OR v_sent_at IS NULL THEN
    RAISE EXCEPTION 'GEVAL 8 GEFAALD: status is % en sent_at is % na een geslaagde verzending.', v_status, v_sent_at;
  END IF;
  RAISE NOTICE 'GEVAL 8 geslaagd: uitkomst teruggeschreven als sent.';

  RAISE NOTICE 'ALLE GEVALLEN GESLAAGD — de ROLLBACK hierna draait de testdata terug (ook het verwijderde nummer).';
END;
$$;

ROLLBACK;
