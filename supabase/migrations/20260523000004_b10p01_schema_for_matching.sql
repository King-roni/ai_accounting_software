-- B10·P01 — Schema for Matching.
-- Adds the rejection-memory table + split-payment-groups table on top of
-- the match_records row already provisioned by Block 04 Phase 03, plus the
-- FK + member-count trigger that ties match_records → split_payment_groups.

-- 1. Enums -------------------------------------------------------------------

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname='split_payment_group_status_enum' AND typnamespace='public'::regnamespace) THEN
    CREATE TYPE public.split_payment_group_status_enum AS ENUM ('PROPOSED','CONFIRMED','REJECTED');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname='split_payment_parent_target_kind_enum' AND typnamespace='public'::regnamespace) THEN
    CREATE TYPE public.split_payment_parent_target_kind_enum AS ENUM ('INVOICE','EXTERNAL_INVOICE','MULTIPLE');
  END IF;
END$$;


-- 2. split_payment_groups ----------------------------------------------------

CREATE TABLE IF NOT EXISTS public.split_payment_groups (
  id                      uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id         uuid NOT NULL,
  business_id             uuid NOT NULL,
  parent_target_kind      public.split_payment_parent_target_kind_enum NOT NULL,
  parent_target_id        uuid,
  proposed_total_amount   numeric NOT NULL,
  currency                char(3) NOT NULL,
  status                  public.split_payment_group_status_enum NOT NULL DEFAULT 'PROPOSED',
  proposed_at             timestamptz NOT NULL DEFAULT clock_timestamp(),
  confirmed_by            uuid,
  confirmed_at            timestamptz,
  rejected_by             uuid,
  rejected_at             timestamptz,
  member_count            integer NOT NULL DEFAULT 0,
  CONSTRAINT spg_amount_positive CHECK (proposed_total_amount > 0),
  CONSTRAINT spg_member_count_nonneg CHECK (member_count >= 0),
  CONSTRAINT spg_parent_target_pairing CHECK (
    (parent_target_kind = 'MULTIPLE' AND parent_target_id IS NULL)
    OR (parent_target_kind IN ('INVOICE','EXTERNAL_INVOICE') AND parent_target_id IS NOT NULL)
  ),
  CONSTRAINT spg_confirmed_pairing CHECK (
    (status <> 'CONFIRMED') OR (confirmed_at IS NOT NULL AND confirmed_by IS NOT NULL)
  ),
  CONSTRAINT spg_rejected_pairing CHECK (
    (status <> 'REJECTED') OR (rejected_at IS NOT NULL AND rejected_by IS NOT NULL)
  ),
  CONSTRAINT spg_org_fk      FOREIGN KEY (organization_id) REFERENCES public.organizations(id)    ON DELETE RESTRICT,
  CONSTRAINT spg_business_fk FOREIGN KEY (business_id)     REFERENCES public.business_entities(id) ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS spg_by_business_status
  ON public.split_payment_groups (business_id, status);

ALTER TABLE public.split_payment_groups ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS spg_select ON public.split_payment_groups;
CREATE POLICY spg_select ON public.split_payment_groups FOR SELECT
  USING (organization_id = public.current_org() AND business_id = ANY (public.current_user_businesses()));
DROP POLICY IF EXISTS spg_no_insert ON public.split_payment_groups;
CREATE POLICY spg_no_insert ON public.split_payment_groups FOR INSERT WITH CHECK (false);
DROP POLICY IF EXISTS spg_no_update ON public.split_payment_groups;
CREATE POLICY spg_no_update ON public.split_payment_groups FOR UPDATE USING (false);
DROP POLICY IF EXISTS spg_no_delete ON public.split_payment_groups;
CREATE POLICY spg_no_delete ON public.split_payment_groups FOR DELETE USING (false);


-- 3. match_rejection_memory --------------------------------------------------

CREATE TABLE IF NOT EXISTS public.match_rejection_memory (
  id                        uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  organization_id           uuid NOT NULL,
  business_id               uuid NOT NULL,
  transaction_id            uuid NOT NULL,
  document_id               uuid NOT NULL,
  rejected_by               uuid NOT NULL,
  rejected_at               timestamptz NOT NULL DEFAULT clock_timestamp(),
  rejection_reason          text,
  original_match_record_id  uuid,
  CONSTRAINT mrm_org_fk         FOREIGN KEY (organization_id) REFERENCES public.organizations(id)    ON DELETE RESTRICT,
  CONSTRAINT mrm_business_fk    FOREIGN KEY (business_id)     REFERENCES public.business_entities(id) ON DELETE RESTRICT,
  CONSTRAINT mrm_transaction_fk FOREIGN KEY (transaction_id)  REFERENCES public.transactions(id)     ON DELETE RESTRICT,
  CONSTRAINT mrm_document_fk    FOREIGN KEY (document_id)     REFERENCES public.documents(id)        ON DELETE RESTRICT
);

CREATE UNIQUE INDEX IF NOT EXISTS mrm_unique_business_pair
  ON public.match_rejection_memory (business_id, transaction_id, document_id);
CREATE INDEX IF NOT EXISTS mrm_by_business_txn
  ON public.match_rejection_memory (business_id, transaction_id);
CREATE INDEX IF NOT EXISTS mrm_by_business_doc
  ON public.match_rejection_memory (business_id, document_id);

ALTER TABLE public.match_rejection_memory ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS mrm_select ON public.match_rejection_memory;
CREATE POLICY mrm_select ON public.match_rejection_memory FOR SELECT
  USING (organization_id = public.current_org() AND business_id = ANY (public.current_user_businesses()));
DROP POLICY IF EXISTS mrm_no_insert ON public.match_rejection_memory;
CREATE POLICY mrm_no_insert ON public.match_rejection_memory FOR INSERT WITH CHECK (false);
DROP POLICY IF EXISTS mrm_no_update ON public.match_rejection_memory;
CREATE POLICY mrm_no_update ON public.match_rejection_memory FOR UPDATE USING (false);
DROP POLICY IF EXISTS mrm_no_delete ON public.match_rejection_memory;
CREATE POLICY mrm_no_delete ON public.match_rejection_memory FOR DELETE USING (false);


-- 4. Add FK on match_records.split_payment_group_id --------------------------
-- The column existed since B04·P03 as an unlinked uuid; now connect it.

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint c
    JOIN pg_class t ON t.oid=c.conrelid
    WHERE t.relname='match_records' AND c.conname='match_records_split_payment_group_fk'
  ) THEN
    ALTER TABLE public.match_records
      ADD CONSTRAINT match_records_split_payment_group_fk
      FOREIGN KEY (split_payment_group_id)
      REFERENCES public.split_payment_groups(id)
      ON DELETE RESTRICT;
  END IF;
END$$;


-- 5. Member-count maintenance trigger ----------------------------------------

CREATE OR REPLACE FUNCTION public.spg_maintain_member_count()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF (TG_OP = 'INSERT') THEN
    IF NEW.split_payment_group_id IS NOT NULL THEN
      UPDATE public.split_payment_groups
        SET member_count = member_count + 1
      WHERE id = NEW.split_payment_group_id;
    END IF;
    RETURN NEW;
  ELSIF (TG_OP = 'UPDATE') THEN
    IF NEW.split_payment_group_id IS DISTINCT FROM OLD.split_payment_group_id THEN
      IF OLD.split_payment_group_id IS NOT NULL THEN
        UPDATE public.split_payment_groups
          SET member_count = member_count - 1
        WHERE id = OLD.split_payment_group_id;
      END IF;
      IF NEW.split_payment_group_id IS NOT NULL THEN
        UPDATE public.split_payment_groups
          SET member_count = member_count + 1
        WHERE id = NEW.split_payment_group_id;
      END IF;
    END IF;
    RETURN NEW;
  ELSIF (TG_OP = 'DELETE') THEN
    IF OLD.split_payment_group_id IS NOT NULL THEN
      UPDATE public.split_payment_groups
        SET member_count = member_count - 1
      WHERE id = OLD.split_payment_group_id;
    END IF;
    RETURN OLD;
  END IF;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS spg_member_count_trigger ON public.match_records;
CREATE TRIGGER spg_member_count_trigger
  AFTER INSERT OR UPDATE OF split_payment_group_id OR DELETE
  ON public.match_records
  FOR EACH ROW EXECUTE FUNCTION public.spg_maintain_member_count();


-- 6. Privileges --------------------------------------------------------------

GRANT SELECT ON public.split_payment_groups   TO authenticated, anon;
GRANT SELECT ON public.match_rejection_memory TO authenticated, anon;
