-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — bevestigingsmail: tabellen, triggers, sweep — 016
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 011 (courier_contacts) eerst; die tabel krijgt hier een kolom.
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien, en draai daarna       │
-- │ supabase/tests/016_shift_mail_test.sql.                                │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- Het volledige ontwerp met de redenen staat in docs/FASE5_MAIL_ONTWERP.md.
-- Samengevat: de koerier krijgt een mail zodra een dienst definitief wordt, en
-- de eenheid is de AFSPRAAK en niet de dienst — tien donderdagen uit dezelfde
-- roosterregel zijn één bericht. Daarmee is shift_id niet de sleutel.
--
-- Twee invarianten:
--   1. Voor elke bevestigde dienst die nog moet gebeuren bestaat er een actieve
--      aankondiging die die dienst dekt. De sweep maakt dat waar.
--   2. Tijdsverloop mag een aankondiging laten vervallen of versmallen, maar
--      nooit een bericht veroorzaken. Alleen een ingreep kan dat, en die wordt
--      vastgelegd (dirtied_at) in plaats van afgeleid — want een variant die
--      uit het venster loopt is rekenkundig niet te onderscheiden van een
--      variant die is weggewijzigd.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────
-- 1. E-mailadres: bron is auth.users, met een uitzondering per koerier.
--    Geen kopie van het adres: dat is precies de spiegel die migratie 008 al
--    een keer heeft afgestraft (user_profiles.pharmacy_ids liep uiteen met de
--    werkelijkheid). email_override is er voor het geval het inlogadres geen
--    werkende postbus is.
-- ────────────────────────────────────────────────────────────────────────
ALTER TABLE public.courier_contacts
  ADD COLUMN IF NOT EXISTS email_override TEXT
    CHECK (email_override IS NULL OR position('@' in email_override) > 1);


-- ────────────────────────────────────────────────────────────────────────
-- 2. courier_announcements — wat is er gemeld, en wat dekte dat.
--    De partiële unieke index dwingt af dat er hoogstens één ACTIEVE
--    aankondiging per subject per koerier is; de geschiedenis blijft staan.
--    Zelfde patroon als shifts_schedule_date_uniq (migratie 009).
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.courier_announcements (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_type      TEXT NOT NULL CHECK (subject_type IN ('schedule', 'shift')),
  subject_id        UUID NOT NULL,        -- polymorf: geen FK mogelijk of wenselijk
  courier_id        UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  covered_variants  TEXT[] NOT NULL,
  announced_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  dirtied_at        TIMESTAMPTZ,          -- er is ingegrepen sinds de aankondiging
  superseded_at     TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS courier_announcements_active_uniq
  ON public.courier_announcements (subject_type, subject_id, courier_id)
  WHERE superseded_at IS NULL;


-- ────────────────────────────────────────────────────────────────────────
-- 3. mail_outbox — wat er verstuurd moet worden.
--    payload is een KOPIE, geen verwijzing: een afmelding gaat per definitie
--    over een dienst die niet meer bestaat. Daarom ook geen FK naar shifts.
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.mail_outbox (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  courier_id          UUID NOT NULL REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  -- 'schedule_cancelled' is nog niet in gebruik: het wegvallen van één datum is
  -- altijd een shift-feit, ook binnen een afspraak. De waarde staat er zodat het
  -- beëindigen van een hele afspraak later geen schemawijziging vergt — zelfde
  -- ruimte-vooraf als bij shifts.status in migratie 001.
  kind                TEXT NOT NULL CHECK (kind IN (
                        'schedule_confirmed', 'schedule_changed', 'schedule_cancelled',
                        'shift_confirmed',    'shift_changed',    'shift_cancelled')),
  subject_type        TEXT,               -- herleidbaarheid; geen FK
  subject_id          UUID,
  payload             JSONB NOT NULL,
  status              TEXT NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending', 'sending', 'sent', 'failed')),
  recipient           TEXT,               -- pas bij verzenden bepaald en vastgelegd
  claimed_at          TIMESTAMPTZ,
  sent_at             TIMESTAMPTZ,
  provider_message_id TEXT,
  error               TEXT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS mail_outbox_pending_idx
  ON public.mail_outbox (courier_id, created_at) WHERE status = 'pending';


-- ────────────────────────────────────────────────────────────────────────
-- 4. Hulpfuncties: venster, variant, subject.
--    Het venster is exact dezelfde uitdrukking als in sms_due_shifts
--    (migratie 012), zodat er in de hele planner één definitie is van
--    "staat nog te gebeuren".
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.mail_is_upcoming(p_date DATE, p_time TIME)
RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
  SELECT (p_date + p_time) AT TIME ZONE 'Europe/Amsterdam' > now();
$$;

-- Eén variant per onderscheidbare verplichting. Bij een afspraak telt de
-- WEEKDAG (de losse datums horen er bewust niet in: dan zou elke volgende
-- bevestiging opnieuw nieuws zijn), bij een losse dienst de datum zelf.
-- car_is_own zit er niet in — administratief; transport_mode wel, want dat
-- bepaalt wat de koerier meeneemt.
CREATE OR REPLACE FUNCTION public.mail_shift_variant(p_shift_id UUID, p_by_weekday BOOLEAN)
RETURNS TEXT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT concat_ws('|',
    CASE WHEN p_by_weekday
         THEN 'dow' || EXTRACT(ISODOW FROM s.shift_date)::TEXT
         ELSE to_char(s.shift_date, 'YYYY-MM-DD') END,
    to_char(s.start_time, 'HH24:MI'),
    COALESCE(to_char(s.budgeted_end_time, 'HH24:MI'), '-'),
    s.transport_mode,
    COALESCE((SELECT string_agg(sp.pharmacy_id, ',' ORDER BY sp.pharmacy_id)
              FROM public.shift_pharmacies sp WHERE sp.shift_id = s.id), '-')
  )
  FROM public.shifts s WHERE s.id = p_shift_id;
$$;

-- Het subject van een dienst. Een roosterdienst hoort bij de AFSPRAAK, maar
-- alleen als de koerier ook de koerier van de roosterregel is: een handmatig
-- toegewezen open roosterdienst is voor die koerier een losse dienst, geen
-- wekelijkse verplichting.
CREATE OR REPLACE FUNCTION public.mail_subject_of(p_shift_id UUID)
RETURNS TABLE (subject_type TEXT, subject_id UUID)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT
    CASE WHEN s.schedule_id IS NOT NULL AND ps.courier_id IS NOT DISTINCT FROM s.courier_id
         THEN 'schedule' ELSE 'shift' END,
    CASE WHEN s.schedule_id IS NOT NULL AND ps.courier_id IS NOT DISTINCT FROM s.courier_id
         THEN s.schedule_id ELSE s.id END
  FROM public.shifts s
  LEFT JOIN public.pharmacy_schedules ps ON ps.id = s.schedule_id
  WHERE s.id = p_shift_id;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 5. mail_upcoming_subjects — de huidige stand: per (subject, koerier) de
--    varianten over bevestigde diensten die nog moeten gebeuren.
--    Eén view, zodat de sweep en de opschoning naar dezelfde definitie kijken.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE VIEW public.mail_upcoming_subjects AS
  WITH upcoming AS (
    SELECT s.id, s.courier_id,
           CASE WHEN s.schedule_id IS NOT NULL AND ps.courier_id IS NOT DISTINCT FROM s.courier_id
                THEN 'schedule' ELSE 'shift' END AS subject_type,
           CASE WHEN s.schedule_id IS NOT NULL AND ps.courier_id IS NOT DISTINCT FROM s.courier_id
                THEN s.schedule_id ELSE s.id END AS subject_id
    FROM public.shifts s
    LEFT JOIN public.pharmacy_schedules ps ON ps.id = s.schedule_id
    WHERE s.status = 'planned'
      AND s.courier_id IS NOT NULL
      AND public.mail_is_upcoming(s.shift_date, s.start_time)
  )
  SELECT u.subject_type,
         u.subject_id,
         u.courier_id,
         array_agg(DISTINCT public.mail_shift_variant(u.id, u.subject_type = 'schedule')) AS variants
  FROM upcoming u
  GROUP BY 1, 2, 3;

REVOKE ALL ON public.mail_upcoming_subjects FROM PUBLIC, anon, authenticated;


-- ────────────────────────────────────────────────────────────────────────
-- 6. mail_subject_payload — de tekstgegevens, afgeleid uit de BEVESTIGDE
--    diensten en niet uit de roosterregel. pharmacy_schedules is een
--    generator van concepten: na een tijdswijziging zegt die regel 08:15
--    terwijl er niets op 08:15 bevestigd is. end_date komt er wél uit — die
--    heeft geen weerslag in de diensten — maar is nadrukkelijk de horizon van
--    de afspraak en geen bevestigde dienst.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.mail_subject_payload(
  p_subject_type TEXT, p_subject_id UUID, p_courier_id UUID
)
RETURNS JSONB
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT jsonb_build_object(
    'subject_type', p_subject_type,
    'courier_name', (SELECT name FROM public.user_profiles WHERE id = p_courier_id),
    'end_date',     CASE WHEN p_subject_type = 'schedule'
                         THEN (SELECT end_date FROM public.pharmacy_schedules WHERE id = p_subject_id)
                    END,
    'shifts', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'shift_date',        s.shift_date,
               'weekday',           EXTRACT(ISODOW FROM s.shift_date),
               'start_time',        to_char(s.start_time, 'HH24:MI'),
               'budgeted_end_time', to_char(s.budgeted_end_time, 'HH24:MI'),
               'transport_mode',    s.transport_mode,
               'pharmacies',        (SELECT COALESCE(jsonb_agg(p.name ORDER BY p.name), '[]'::jsonb)
                                     FROM public.shift_pharmacies sp
                                     JOIN public.pharmacies p ON p.id = sp.pharmacy_id
                                     WHERE sp.shift_id = s.id)
             ) ORDER BY s.shift_date, s.start_time)
      FROM public.shifts s
      LEFT JOIN public.pharmacy_schedules ps ON ps.id = s.schedule_id
      WHERE s.status = 'planned'
        AND s.courier_id = p_courier_id
        AND public.mail_is_upcoming(s.shift_date, s.start_time)
        AND CASE WHEN p_subject_type = 'schedule'
                 THEN s.schedule_id = p_subject_id
                      AND ps.courier_id IS NOT DISTINCT FROM s.courier_id
                 ELSE s.id = p_subject_id END
    ), '[]'::jsonb)
  );
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 7. mail_sweep — het volledige besluit uit het ontwerp, in één functie.
--
--   V = varianten in het venster, C = covered_variants van de aankondiging.
--   bij = V ⊄ C   (er is iets bijgekomen)
--   af  = C ⊄ V   (er is iets verdwenen)
--
--   geen aankondiging, V niet leeg  → aankondigen              → BERICHT
--   bij                             → vervangen                → BERICHT
--   vlag én af (en niet bij)        → vervangen                → BERICHT
--   vlag én V = C                   → alleen vlag wissen       → stil
--   geen vlag én af                 → covered := C ∩ V         → stil (klok)
--   V leeg                          → laten vervallen          → stil (klok)
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.mail_sweep()
RETURNS TABLE (announced INT, changed INT, narrowed INT, retired INT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  r        RECORD;
  v_ann    public.courier_announcements;
  v_claim  UUID;
  v_bij    BOOLEAN;
  v_af     BOOLEAN;
  v_new    BOOLEAN;
BEGIN
  announced := 0; changed := 0; narrowed := 0; retired := 0;

  FOR r IN SELECT * FROM public.mail_upcoming_subjects LOOP
    SELECT * INTO v_ann
    FROM public.courier_announcements a
    WHERE a.subject_type = r.subject_type
      AND a.subject_id   = r.subject_id
      AND a.courier_id   = r.courier_id
      AND a.superseded_at IS NULL;

    -- ── Nog nooit gemeld ────────────────────────────────────────────────
    IF v_ann.id IS NULL THEN
      -- ON CONFLICT DO NOTHING is de gate: draaien er twee sweeps tegelijk,
      -- dan wint er één en schrijft alleen die een outbox-rij.
      INSERT INTO public.courier_announcements
        (subject_type, subject_id, courier_id, covered_variants)
      VALUES (r.subject_type, r.subject_id, r.courier_id, r.variants)
      ON CONFLICT DO NOTHING
      RETURNING id INTO v_claim;

      IF v_claim IS NOT NULL THEN
        PERFORM public.mail_enqueue(r.subject_type, r.subject_id, r.courier_id,
                                    r.subject_type || '_confirmed');
        announced := announced + 1;
      END IF;
      CONTINUE;
    END IF;

    v_bij := NOT (r.variants <@ v_ann.covered_variants);
    v_af  := NOT (v_ann.covered_variants <@ r.variants);
    -- Verdwijnen is alleen nieuws als er is ingegrepen; zonder vlag komt het
    -- van de klok en dan hoort er niets uit te gaan.
    v_new := v_bij OR (v_ann.dirtied_at IS NOT NULL AND v_af);

    IF v_new THEN
      UPDATE public.courier_announcements
         SET superseded_at = now()
       WHERE id = v_ann.id AND superseded_at IS NULL
      RETURNING id INTO v_claim;

      IF v_claim IS NOT NULL THEN
        INSERT INTO public.courier_announcements
          (subject_type, subject_id, courier_id, covered_variants)
        VALUES (r.subject_type, r.subject_id, r.courier_id, r.variants);

        PERFORM public.mail_enqueue(r.subject_type, r.subject_id, r.courier_id,
                                    r.subject_type || '_changed');
        changed := changed + 1;
      END IF;

    ELSIF v_af THEN
      -- Versmallen door tijdsverloop. Nodig, want anders blijft een variant die
      -- uit het venster liep voor altijd als "al gemeld" gelden en is een
      -- terugdraaiing later geen nieuws meer.
      UPDATE public.courier_announcements
         SET covered_variants = ARRAY(
               SELECT v FROM unnest(covered_variants) v
               INTERSECT SELECT w FROM unnest(r.variants) w),
             dirtied_at = NULL
       WHERE id = v_ann.id AND superseded_at IS NULL;
      narrowed := narrowed + 1;

    ELSIF v_ann.dirtied_at IS NOT NULL THEN
      -- Ingegrepen, maar per saldo niets veranderd (aangepast en teruggezet).
      UPDATE public.courier_announcements SET dirtied_at = NULL
       WHERE id = v_ann.id AND superseded_at IS NULL;
    END IF;
  END LOOP;

  -- ── Niets meer vóór: aankondiging laten vervallen, zwijgend ────────────
  -- Afmeldingen zijn al langs de triggers gegaan. Bevestigt de planner later
  -- opnieuw diensten, dan is dat weer nieuws — precies wat je wilt.
  WITH vervallen AS (
    UPDATE public.courier_announcements a
       SET superseded_at = now()
     WHERE a.superseded_at IS NULL
       AND NOT EXISTS (
         SELECT 1 FROM public.mail_upcoming_subjects u
         WHERE u.subject_type = a.subject_type
           AND u.subject_id   = a.subject_id
           AND u.courier_id   = a.courier_id)
    RETURNING 1)
  SELECT count(*) INTO retired FROM vervallen;

  RETURN NEXT;
END;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 8. mail_enqueue — één outbox-rij, met de gegevens gekopieerd.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.mail_enqueue(
  p_subject_type TEXT, p_subject_id UUID, p_courier_id UUID, p_kind TEXT
)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id UUID;
BEGIN
  INSERT INTO public.mail_outbox (courier_id, kind, subject_type, subject_id, payload)
  VALUES (p_courier_id, p_kind, p_subject_type, p_subject_id,
          public.mail_subject_payload(p_subject_type, p_subject_id, p_courier_id))
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;


-- ────────────────────────────────────────────────────────────────────────
-- 9. Trigger: ingreep vastleggen.
--    Zet de vlag op de actieve aankondiging. GEEN outbox-rij: de sweep bepaalt
--    of er per saldo iets veranderd is en levert de tekst met de actuele stand.
--    Bewust een vlag en geen superseded_at: bij superseden zou aanpassen-en-
--    terugzetten alsnog een bericht opleveren.
--    courier_id staat niet in de kolomlijst — een wissel gaat langs punt 10.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.mail_mark_dirty(p_shift_id UUID)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_subj RECORD; v_courier UUID; v_status TEXT;
BEGIN
  SELECT courier_id, status INTO v_courier, v_status FROM public.shifts WHERE id = p_shift_id;
  IF v_courier IS NULL OR v_status <> 'planned' THEN RETURN; END IF;

  SELECT * INTO v_subj FROM public.mail_subject_of(p_shift_id);
  IF v_subj.subject_id IS NULL THEN RETURN; END IF;

  UPDATE public.courier_announcements
     SET dirtied_at = now()
   WHERE subject_type = v_subj.subject_type
     AND subject_id   = v_subj.subject_id
     AND courier_id   = v_courier
     AND superseded_at IS NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.mail_shift_dirty_trg()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.mail_mark_dirty(NEW.id);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS mail_shift_dirty ON public.shifts;
CREATE TRIGGER mail_shift_dirty
  AFTER UPDATE OF shift_date, start_time, budgeted_end_time, transport_mode
  ON public.shifts
  FOR EACH ROW EXECUTE FUNCTION public.mail_shift_dirty_trg();

-- Apotheken horen bij de variant, dus een wijziging daarin is ook een ingreep.
CREATE OR REPLACE FUNCTION public.mail_pharmacy_dirty_trg()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  PERFORM public.mail_mark_dirty(COALESCE(NEW.shift_id, OLD.shift_id));
  RETURN COALESCE(NEW, OLD);
END;
$$;

DROP TRIGGER IF EXISTS mail_shift_pharmacy_dirty ON public.shift_pharmacies;
CREATE TRIGGER mail_shift_pharmacy_dirty
  AFTER INSERT OR DELETE ON public.shift_pharmacies
  FOR EACH ROW EXECUTE FUNCTION public.mail_pharmacy_dirty_trg();


-- ────────────────────────────────────────────────────────────────────────
-- 10. Triggers: afmelden.
--     BEFORE DELETE en niet AFTER: shift_pharmacies ruimt zichzelf op via
--     ON DELETE CASCADE, dus in een AFTER-trigger zijn de apotheeknamen weg.
--     Alleen voor diensten die nog moesten gebeuren — een afgeronde dienst
--     verwijderen is administratie, geen nieuws.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.mail_cancel_trg()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_courier     UUID := OLD.courier_id;   -- altijd de OUDE koerier: die verliest de dienst
  v_is_schedule BOOLEAN;
  v_subject_id  UUID;
  v_payload     JSONB;
BEGIN
  -- Bij een koerierwissel alleen doorgaan als de koerier daadwerkelijk wijzigt.
  IF TG_OP = 'UPDATE' AND NEW.courier_id IS NOT DISTINCT FROM OLD.courier_id THEN
    RETURN NEW;
  END IF;

  IF v_courier IS NULL
     OR OLD.status <> 'planned'
     OR NOT public.mail_is_upcoming(OLD.shift_date, OLD.start_time) THEN
    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
  END IF;

  -- Subject uit OLD bepalen en niet via mail_subject_of(): bij een wissel is de
  -- rij al bijgewerkt, en dan zou de helper het subject van de NIEUWE koerier
  -- teruggeven terwijl dit bericht over de oude gaat.
  v_is_schedule := OLD.schedule_id IS NOT NULL
    AND (SELECT ps.courier_id FROM public.pharmacy_schedules ps WHERE ps.id = OLD.schedule_id)
        IS NOT DISTINCT FROM v_courier;
  v_subject_id := CASE WHEN v_is_schedule THEN OLD.schedule_id ELSE OLD.id END;

  -- Gegevens kopiëren: na deze trigger is de rij (of de koppeling) weg.
  v_payload := jsonb_build_object(
    'subject_type', CASE WHEN v_is_schedule THEN 'schedule' ELSE 'shift' END,
    'courier_name', (SELECT name FROM public.user_profiles WHERE id = v_courier),
    'shift_date',   OLD.shift_date,
    'weekday',      EXTRACT(ISODOW FROM OLD.shift_date),
    'start_time',   to_char(OLD.start_time, 'HH24:MI'),
    'budgeted_end_time', to_char(OLD.budgeted_end_time, 'HH24:MI'),
    'transport_mode', OLD.transport_mode,
    'pharmacies',   (SELECT COALESCE(jsonb_agg(p.name ORDER BY p.name), '[]'::jsonb)
                     FROM public.shift_pharmacies sp
                     JOIN public.pharmacies p ON p.id = sp.pharmacy_id
                     WHERE sp.shift_id = OLD.id),
    'reason',       CASE TG_OP WHEN 'DELETE' THEN 'verwijderd' ELSE 'andere koerier' END
  );

  INSERT INTO public.mail_outbox (courier_id, kind, subject_type, subject_id, payload)
  VALUES (v_courier, 'shift_cancelled',
          CASE WHEN v_is_schedule THEN 'schedule' ELSE 'shift' END, v_subject_id, v_payload);

  IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$$;

DROP TRIGGER IF EXISTS mail_shift_cancel ON public.shifts;
CREATE TRIGGER mail_shift_cancel
  BEFORE DELETE ON public.shifts
  FOR EACH ROW EXECUTE FUNCTION public.mail_cancel_trg();

DROP TRIGGER IF EXISTS mail_shift_reassign ON public.shifts;
CREATE TRIGGER mail_shift_reassign
  AFTER UPDATE OF courier_id ON public.shifts
  FOR EACH ROW EXECUTE FUNCTION public.mail_cancel_trg();


-- ────────────────────────────────────────────────────────────────────────
-- 11. RLS — planners lezen mee (statuskolom in de planner). Schrijven gebeurt
--     uitsluitend via de SECURITY DEFINER-functies en de sweep (service-role).
-- ────────────────────────────────────────────────────────────────────────
ALTER TABLE public.courier_announcements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mail_outbox           ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "announcements_privileged_read" ON public.courier_announcements;
CREATE POLICY "announcements_privileged_read" ON public.courier_announcements
  FOR SELECT USING (public.is_privileged());

DROP POLICY IF EXISTS "outbox_privileged_read" ON public.mail_outbox;
CREATE POLICY "outbox_privileged_read" ON public.mail_outbox
  FOR SELECT USING (public.is_privileged());


-- ────────────────────────────────────────────────────────────────────────
-- 12. Rechten — de sweep en de hulpfuncties zijn uitsluitend voor de job.
--     EXECUTE staat standaard aan voor PUBLIC; dat moet er expliciet af, want
--     deze functies omzeilen als SECURITY DEFINER de RLS.
-- ────────────────────────────────────────────────────────────────────────
REVOKE ALL ON FUNCTION public.mail_sweep()                              FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mail_enqueue(TEXT, UUID, UUID, TEXT)      FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mail_subject_payload(TEXT, UUID, UUID)    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mail_shift_variant(UUID, BOOLEAN)         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mail_subject_of(UUID)                     FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.mail_mark_dirty(UUID)                     FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.mail_sweep()                           TO service_role;
GRANT SELECT  ON public.mail_upcoming_subjects                           TO service_role;


-- ────────────────────────────────────────────────────────────────────────
-- 13. Vullen bij installatie — de belangrijkste stap van deze migratie.
--     Zonder dit meldt de eerste sweep de hele bestaande planning aan alle
--     koeriers. Verstuurde mail is niet terug te halen.
--     Let op: aankondigingen aanmaken ZONDER outbox-rijen.
-- ────────────────────────────────────────────────────────────────────────
INSERT INTO public.courier_announcements
  (subject_type, subject_id, courier_id, covered_variants)
SELECT u.subject_type, u.subject_id, u.courier_id, u.variants
FROM public.mail_upcoming_subjects u
ON CONFLICT DO NOTHING;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie — verwacht: aantal aankondigingen = aantal subjecten met
-- aanstaande diensten, en een LEGE outbox.
-- ────────────────────────────────────────────────────────────────────────
SELECT
  (SELECT count(*) FROM public.mail_upcoming_subjects)                          AS subjecten,
  (SELECT count(*) FROM public.courier_announcements WHERE superseded_at IS NULL) AS aankondigingen,
  (SELECT count(*) FROM public.mail_outbox)                                     AS outbox_moet_0_zijn;

COMMIT;   -- ← vervang door ROLLBACK; voor een dry-run zonder op te slaan
