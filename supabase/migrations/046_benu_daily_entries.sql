-- ════════════════════════════════════════════════════════════════════════
-- Greenspeed Planner — BENU selfbilling: dagelijkse koerier-invoer — 046
-- ════════════════════════════════════════════════════════════════════════
-- Uitvoeren in de Supabase SQL Editor van de gedeelde Greenspeed-database.
-- Draai migratie 044 eerst (die zette pharmacies.is_benu_selfbilling).
--
-- ┌─ DRY-RUN EERST ────────────────────────────────────────────────────────┐
-- │ Dit bestand staat binnen een transactie (BEGIN … COMMIT). Vervang de   │
-- │ laatste regel door ROLLBACK; om te proefdraaien.                       │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- WAAROM TWEE TABELLEN
--   De koerier vult één formulier in voor zijn hele dienst, maar de goedkeuring
--   van extra minuten gaat per apotheek: die twee hebben een verschillende
--   levensloop en een verschillende ontvanger. Eén tabel zou de status van drie
--   apotheken in één rij moeten persen.
--
-- GEEN GENERATED COLUMN VOOR extra_minutes
--   Extra tijd is altijd pda_minutes - planned_minutes, minimaal 0. Omdat
--   planned_minutes NULL kan zijn (geen begroting) is dat geen som die je in een
--   generated column wilt vastleggen: NULL zou dan door de hele keten lekken.
--   De afleiding staat in de RPC's, op één plek.
--
-- TOEGANG: ALLEEN VIA DE EDGE FUNCTIONS
--   Zelfde opzet als extra_work (migratie 031): RLS aan zónder één policy, plus
--   REVOKE. Anon en authenticated komen er niet bij, ook niet als er later per
--   ongeluk een GRANT wordt uitgedeeld. Het token in de URL is het hele bewijs;
--   de service-role achter de Edge Function is de enige weg naar deze rijen.
--
-- TYPES VOLGEN HET BESTAANDE SCHEMA
--   shifts.id en shifts.courier_id zijn UUID (migratie 001), niet TEXT, en
--   shifts.shift_date is DATE. De kolommen hieronder volgen dat; anders zou de
--   foreign key niet eens aangemaakt kunnen worden. pharmacies.id ís TEXT en
--   blijft dat dus.
-- ════════════════════════════════════════════════════════════════════════

BEGIN;

-- ────────────────────────────────────────────────────────────────────────
-- 1. benu_shift_entries — één rij per dienst (de koerier vult één formulier in)
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.benu_shift_entries (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),

  -- UNIQUE is de idempotentiesleutel waar benu_claim_shift op steunt: twee
  -- cron-runs naast elkaar mogen samen niet twee formulieren opleveren.
  shift_id         UUID        NOT NULL UNIQUE
                               REFERENCES public.shifts(id) ON DELETE CASCADE,
  courier_id       UUID        NOT NULL
                               REFERENCES public.user_profiles(id) ON DELETE CASCADE,
  courier_token    UUID        NOT NULL UNIQUE DEFAULT gen_random_uuid(),

  -- Ingevuld door de koerier; NULL = nog niet ingediend.
  submitted_at     TIMESTAMPTZ,
  -- Token geldig tot 10:00 de volgende ochtend; berekend door de aanroeper.
  token_expires_at TIMESTAMPTZ NOT NULL,
  courier_note     TEXT,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS benu_shift_entries_courier_idx
  ON public.benu_shift_entries (courier_id);

-- ────────────────────────────────────────────────────────────────────────
-- 2. benu_pharmacy_entries — één rij per dienst-apotheek (de apotheek keurt goed)
-- ────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.benu_pharmacy_entries (
  id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  shift_entry_id   UUID        NOT NULL
                               REFERENCES public.benu_shift_entries(id) ON DELETE CASCADE,
  pharmacy_id      TEXT        NOT NULL REFERENCES public.pharmacies(id) ON DELETE CASCADE,

  -- Kopie, geen verwijzing: de naam zoals hij op het moment van melden luidde,
  -- zodat een latere naamswijziging de mailhistorie niet met terugwerkende
  -- kracht verandert. Zelfde keuze als bij extra_work (migratie 031).
  pharmacy_name    TEXT        NOT NULL,

  -- Gekopieerd uit shift_pharmacies.budgeted_minutes bij aanmaken (migratie 025).
  -- NULL = geen begroting beschikbaar.
  planned_minutes  INT,
  -- Ingevuld door de koerier.
  pda_minutes      INT,
  -- Verplicht zodra pda_minutes > planned_minutes; de pagina bewaakt dat.
  extra_reason     TEXT,
  -- Voor de apotheekpagina, die net als de koerierspagina zonder inlog werkt.
  pharmacy_token   UUID        NOT NULL UNIQUE DEFAULT gen_random_uuid(),

  --   pending       = aangemaakt, koerier nog niet ingediend
  --   no_extra      = koerier ingediend, pda_minutes <= planned_minutes
  --   submitted     = koerier ingediend, extra_minutes > 0, apotheek kan reageren
  --   approved      = apotheek akkoord
  --   disputed      = apotheek niet akkoord
  --   auto_approved = termijn verstreken zonder reactie
  status           TEXT        NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending','no_extra','submitted','approved','disputed','auto_approved')),

  -- 48 uur na het indienen door de koerier.
  dispute_deadline TIMESTAMPTZ,
  responded_at     TIMESTAMPTZ,
  pharmacy_note    TEXT,

  UNIQUE (shift_entry_id, pharmacy_id)
);

CREATE INDEX IF NOT EXISTS benu_pharmacy_entries_deadline_idx
  ON public.benu_pharmacy_entries (status, dispute_deadline);

-- RLS aan zonder policies = niemand, ook niet na een losse GRANT.
ALTER TABLE public.benu_shift_entries    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.benu_pharmacy_entries ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.benu_shift_entries    FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.benu_pharmacy_entries FROM PUBLIC, anon, authenticated;


-- ════════════════════════════════════════════════════════════════════════
-- RPC's
-- ════════════════════════════════════════════════════════════════════════

-- ────────────────────────────────────────────────────────────────────────
-- benu_shifts_to_mail — diensten van vandaag met ten minste één BENU
-- selfbilling-apotheek waarvoor nog geen formulier klaarstaat.
--
-- Het adres komt uit mail_recipient_for() (migratie 017): dat is de enige plek
-- in het project die auth.users leest, en daar zit de email_override van
-- courier_contacts al in. Rechtstreeks joinen op auth.users zou die override
-- stil overslaan.
--
-- 'draft' valt buiten de selectie: een conceptdienst is voor de koerier niet
-- eens zichtbaar (migratie 005), dus daar hoort geen mail over te gaan.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.benu_shifts_to_mail()
RETURNS TABLE (
  shift_id      UUID,
  shift_date    TEXT,
  courier_id    UUID,
  courier_name  TEXT,
  courier_email TEXT,
  pharmacies    JSONB   -- [{pharmacy_id, pharmacy_name, planned_minutes}]
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT
    s.id,
    to_char(s.shift_date, 'YYYY-MM-DD'),
    s.courier_id,
    up.name,
    (SELECT r.email FROM public.mail_recipient_for(s.courier_id) r),
    jsonb_agg(jsonb_build_object(
      'pharmacy_id',     p.id,
      'pharmacy_name',   p.name,
      'planned_minutes', sp.budgeted_minutes
    ) ORDER BY p.name)
  FROM public.shifts s
  JOIN public.shift_pharmacies sp   ON sp.shift_id = s.id
  JOIN public.pharmacies p          ON p.id = sp.pharmacy_id AND p.is_benu_selfbilling
  LEFT JOIN public.user_profiles up ON up.id = s.courier_id
  WHERE s.shift_date = CURRENT_DATE
    AND s.courier_id IS NOT NULL
    AND s.status IN ('planned', 'assigned')
    AND NOT EXISTS (
      SELECT 1 FROM public.benu_shift_entries b WHERE b.shift_id = s.id
    )
  GROUP BY s.id, s.shift_date, s.courier_id, up.name;
$fn$;

REVOKE ALL ON FUNCTION public.benu_shifts_to_mail() FROM PUBLIC, anon, authenticated;


-- ────────────────────────────────────────────────────────────────────────
-- benu_claim_shift — formulier klaarzetten voor één dienst.
-- Idempotent: bestaat hij al, dan komt het bestaande token terug. De UNIQUE op
-- shift_id maakt dat waar, ook als twee runs elkaar overlappen.
-- p_pharmacies: [{pharmacy_id, pharmacy_name, planned_minutes}]
-- p_expires_at: 10:00 de volgende ochtend, in UTC berekend door de aanroeper.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.benu_claim_shift(
  p_shift_id   UUID,
  p_courier_id UUID,
  p_pharmacies JSONB,
  p_expires_at TIMESTAMPTZ
)
RETURNS TABLE (courier_token UUID)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_entry_id UUID;
  v_token    UUID;
  v_ph       JSONB;
BEGIN
  SELECT b.id, b.courier_token
    INTO v_entry_id, v_token
    FROM public.benu_shift_entries b
   WHERE b.shift_id = p_shift_id;

  IF v_entry_id IS NULL THEN
    INSERT INTO public.benu_shift_entries (shift_id, courier_id, token_expires_at)
    VALUES (p_shift_id, p_courier_id, p_expires_at)
    RETURNING id, benu_shift_entries.courier_token INTO v_entry_id, v_token;

    FOR v_ph IN SELECT * FROM jsonb_array_elements(p_pharmacies) LOOP
      INSERT INTO public.benu_pharmacy_entries
        (shift_entry_id, pharmacy_id, pharmacy_name, planned_minutes)
      VALUES (
        v_entry_id,
        v_ph->>'pharmacy_id',
        v_ph->>'pharmacy_name',
        (v_ph->>'planned_minutes')::INT
      );
    END LOOP;
  END IF;

  RETURN QUERY SELECT v_token;
END;
$fn$;

REVOKE ALL ON FUNCTION public.benu_claim_shift(UUID, UUID, JSONB, TIMESTAMPTZ)
  FROM PUBLIC, anon, authenticated;


-- ────────────────────────────────────────────────────────────────────────
-- benu_entry_by_courier_token — de koerierspagina (GET).
-- Een onbekend token levert niets op; de Edge Function maakt daar één
-- nietszeggend antwoord van. Een verlopen token geeft wél de rij terug, zodat
-- de pagina kan zeggen dát hij verlopen is in plaats van "link ongeldig".
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.benu_entry_by_courier_token(p_token UUID)
RETURNS TABLE (
  shift_id         UUID,
  shift_date       TEXT,
  courier_name     TEXT,
  submitted_at     TIMESTAMPTZ,
  token_expires_at TIMESTAMPTZ,
  courier_note     TEXT,
  pharmacies       JSONB
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT
    s.id,
    to_char(s.shift_date, 'YYYY-MM-DD'),
    up.name,
    bse.submitted_at,
    bse.token_expires_at,
    bse.courier_note,
    jsonb_agg(jsonb_build_object(
      'id',              bpe.id,
      'pharmacy_id',     bpe.pharmacy_id,
      'pharmacy_name',   bpe.pharmacy_name,
      'planned_minutes', bpe.planned_minutes,
      'pda_minutes',     bpe.pda_minutes,
      'extra_reason',    bpe.extra_reason,
      'status',          bpe.status
    ) ORDER BY bpe.pharmacy_name)
  FROM public.benu_shift_entries bse
  JOIN public.shifts s                  ON s.id = bse.shift_id
  JOIN public.benu_pharmacy_entries bpe ON bpe.shift_entry_id = bse.id
  LEFT JOIN public.user_profiles up     ON up.id = bse.courier_id
  WHERE bse.courier_token = p_token
  GROUP BY s.id, s.shift_date, up.name,
           bse.submitted_at, bse.token_expires_at, bse.courier_note;
$fn$;

REVOKE ALL ON FUNCTION public.benu_entry_by_courier_token(UUID)
  FROM PUBLIC, anon, authenticated;


-- ────────────────────────────────────────────────────────────────────────
-- benu_entry_submit — de koerier dient in.
-- p_entries: [{pharmacy_id, pda_minutes, extra_reason}]
-- Geeft de apotheken terug waar extra tijd op zit, mét facturatieadres en
-- token, zodat de Edge Function er meteen een mail heen kan sturen.
--
-- Eenmalig: een tweede poging loopt op 45002 stuk. Anders zou een dubbele klik
-- een tweede ronde apotheekmails opleveren over dezelfde dienst.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.benu_entry_submit(
  p_token   UUID,
  p_entries JSONB,
  p_note    TEXT DEFAULT NULL
)
RETURNS TABLE (
  pharmacy_id     TEXT,
  pharmacy_name   TEXT,
  billing_email   TEXT,
  planned_minutes INT,
  pda_minutes     INT,
  extra_minutes   INT,
  pharmacy_token  UUID
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_entry_id  UUID;
  v_submitted TIMESTAMPTZ;
  v_expires   TIMESTAMPTZ;
  v_e         JSONB;
  v_pda       INT;
  v_planned   INT;
  v_extra     INT;
  v_status    TEXT;
  v_deadline  TIMESTAMPTZ;
BEGIN
  SELECT b.id, b.submitted_at, b.token_expires_at
    INTO v_entry_id, v_submitted, v_expires
    FROM public.benu_shift_entries b
   WHERE b.courier_token = p_token;

  IF v_entry_id IS NULL THEN
    RAISE EXCEPTION 'Deze link is niet (meer) geldig.' USING ERRCODE = '28000';
  END IF;
  IF v_expires < now() THEN
    RAISE EXCEPTION 'De invullink is verlopen.' USING ERRCODE = '45001';
  END IF;
  IF v_submitted IS NOT NULL THEN
    RAISE EXCEPTION 'Je hebt dit formulier al ingediend.' USING ERRCODE = '45002';
  END IF;

  UPDATE public.benu_shift_entries
     SET submitted_at = now(), courier_note = p_note
   WHERE id = v_entry_id;

  FOR v_e IN SELECT * FROM jsonb_array_elements(p_entries) LOOP
    v_pda := (v_e->>'pda_minutes')::INT;

    SELECT bpe.planned_minutes INTO v_planned
      FROM public.benu_pharmacy_entries bpe
     WHERE bpe.shift_entry_id = v_entry_id
       AND bpe.pharmacy_id = v_e->>'pharmacy_id';

    v_extra := GREATEST(0, COALESCE(v_pda, 0) - COALESCE(v_planned, 0));
    IF v_extra > 0 THEN
      v_status   := 'submitted';
      v_deadline := now() + INTERVAL '48 hours';
    ELSE
      v_status   := 'no_extra';
      v_deadline := NULL;
    END IF;

    UPDATE public.benu_pharmacy_entries bpe
       SET pda_minutes      = v_pda,
           extra_reason     = v_e->>'extra_reason',
           status           = v_status,
           dispute_deadline = v_deadline
     WHERE bpe.shift_entry_id = v_entry_id
       AND bpe.pharmacy_id = v_e->>'pharmacy_id';
  END LOOP;

  RETURN QUERY
  SELECT
    bpe.pharmacy_id,
    bpe.pharmacy_name,
    ph.billing_email,
    bpe.planned_minutes,
    bpe.pda_minutes,
    (COALESCE(bpe.pda_minutes, 0) - COALESCE(bpe.planned_minutes, 0))::INT,
    bpe.pharmacy_token
  FROM public.benu_pharmacy_entries bpe
  JOIN public.pharmacies ph ON ph.id = bpe.pharmacy_id
  WHERE bpe.shift_entry_id = v_entry_id
    AND bpe.status = 'submitted';
END;
$fn$;

REVOKE ALL ON FUNCTION public.benu_entry_submit(UUID, JSONB, TEXT)
  FROM PUBLIC, anon, authenticated;


-- ────────────────────────────────────────────────────────────────────────
-- benu_pharmacy_by_token — de apotheekpagina (GET), ook ná een antwoord.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.benu_pharmacy_by_token(p_token UUID)
RETURNS TABLE (
  shift_date       TEXT,
  pharmacy_name    TEXT,
  courier_name     TEXT,
  planned_minutes  INT,
  pda_minutes      INT,
  extra_reason     TEXT,
  status           TEXT,
  dispute_deadline TIMESTAMPTZ,
  responded_at     TIMESTAMPTZ,
  pharmacy_note    TEXT
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $fn$
  SELECT
    to_char(s.shift_date, 'YYYY-MM-DD'),
    bpe.pharmacy_name,
    up.name,
    bpe.planned_minutes,
    bpe.pda_minutes,
    bpe.extra_reason,
    bpe.status,
    bpe.dispute_deadline,
    bpe.responded_at,
    bpe.pharmacy_note
  FROM public.benu_pharmacy_entries bpe
  JOIN public.benu_shift_entries bse ON bse.id = bpe.shift_entry_id
  JOIN public.shifts s               ON s.id = bse.shift_id
  LEFT JOIN public.user_profiles up  ON up.id = bse.courier_id
  WHERE bpe.pharmacy_token = p_token;
$fn$;

REVOKE ALL ON FUNCTION public.benu_pharmacy_by_token(UUID)
  FROM PUBLIC, anon, authenticated;


-- ────────────────────────────────────────────────────────────────────────
-- benu_pharmacy_respond — de apotheek reageert. Eén keer: daarna staat de
-- status niet meer op 'submitted' en levert een tweede poging 45003 op.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.benu_pharmacy_respond(
  p_token   UUID,
  p_approve BOOLEAN,
  p_note    TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
DECLARE
  v_status TEXT;
BEGIN
  SELECT bpe.status INTO v_status
    FROM public.benu_pharmacy_entries bpe
   WHERE bpe.pharmacy_token = p_token;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'Deze link is niet (meer) geldig.' USING ERRCODE = '28000';
  END IF;
  IF v_status <> 'submitted' THEN
    RAISE EXCEPTION 'Er valt niets meer te beslissen over deze melding.' USING ERRCODE = '45003';
  END IF;

  UPDATE public.benu_pharmacy_entries
     SET status        = CASE WHEN p_approve THEN 'approved' ELSE 'disputed' END,
         responded_at  = now(),
         pharmacy_note = p_note
   WHERE pharmacy_token = p_token;
END;
$fn$;

REVOKE ALL ON FUNCTION public.benu_pharmacy_respond(UUID, BOOLEAN, TEXT)
  FROM PUBLIC, anon, authenticated;


-- ────────────────────────────────────────────────────────────────────────
-- benu_check_deadlines — cron: wat de termijn heeft overleefd zonder reactie
-- wordt automatisch goedgekeurd. Geeft het aantal bijgewerkte rijen terug.
-- ────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.benu_check_deadlines()
RETURNS INT
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $fn$
  WITH updated AS (
    UPDATE public.benu_pharmacy_entries
       SET status = 'auto_approved'
     WHERE status = 'submitted'
       AND dispute_deadline < now()
    RETURNING id
  )
  SELECT COUNT(*)::INT FROM updated;
$fn$;

REVOKE ALL ON FUNCTION public.benu_check_deadlines() FROM PUBLIC, anon, authenticated;


-- ────────────────────────────────────────────────────────────────────────
-- Verificatie — wat staat er open. Direct na deze migratie is alles leeg.
-- ────────────────────────────────────────────────────────────────────────
-- SELECT bpe.status, count(*) FROM public.benu_pharmacy_entries bpe GROUP BY 1 ORDER BY 1;
-- SELECT * FROM public.benu_shifts_to_mail();

COMMIT;
