-- =============================================================================
-- BOOK-965 — create_bank_account RPC so a business can add a bank account in-app.
-- =============================================================================
-- A freshly-onboarded business has no bank account, and the statement-upload flow
-- requires one (request_raw_upload → NO_BANK_ACCOUNT_CONFIGURED). There was no UI
-- or RPC to create one (direct writes from `authenticated` are blocked — workflow-
-- first), so the first upload was a dead-end. This SECURITY DEFINER RPC mirrors
-- create_business's auth model: the caller must be OWNER/ADMIN on the business.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.create_bank_account(
  p_business_id uuid,
  p_account_name text,
  p_provider text DEFAULT 'Manual',
  p_currency text DEFAULT 'EUR',
  p_masked_iban text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'audit', 'pg_temp'
AS $function$
DECLARE
  v_user uuid := public.current_user_id();
  v_org  uuid;
  v_id   uuid;
  v_iban text := NULLIF(btrim(p_masked_iban), '');
BEGIN
  IF v_user IS NULL THEN RAISE EXCEPTION 'unauthenticated' USING ERRCODE='28000'; END IF;
  IF p_business_id IS NULL OR p_account_name IS NULL OR length(btrim(p_account_name)) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'INVALID_INPUT');
  END IF;
  SELECT organization_id INTO v_org FROM public.business_entities WHERE id = p_business_id;
  IF v_org IS NULL THEN RETURN jsonb_build_object('ok', false, 'reason', 'BUSINESS_NOT_FOUND'); END IF;
  IF NOT EXISTS (SELECT 1 FROM public.business_user_roles
                 WHERE business_id = p_business_id AND user_id = v_user
                   AND role IN ('OWNER'::public.user_role, 'ADMIN'::public.user_role)
                   AND status = 'ACTIVE'::public.account_status) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'ACCESS_DENIED');
  END IF;

  INSERT INTO public.bank_accounts
    (organization_id, business_id, provider, account_name, currency, masked_iban, iban_masked, status)
  VALUES (v_org, p_business_id,
          COALESCE(NULLIF(btrim(p_provider), ''), 'Manual'),
          btrim(p_account_name),
          upper(COALESCE(NULLIF(btrim(p_currency), ''), 'EUR'))::bpchar,
          v_iban, v_iban, 'ACTIVE'::public.account_status)
  RETURNING id INTO v_id;

  PERFORM audit.emit_audit(
    p_actor_kind => 'USER'::audit.actor_kind_enum, p_action => 'BANK_ACCOUNT_CREATED',
    p_subject_type => 'BANK_ACCOUNT'::audit.subject_type_enum, p_subject_id => v_id,
    p_actor_user_id => v_user, p_organization_id => v_org, p_business_id => p_business_id,
    p_after_state => jsonb_build_object('account_name', btrim(p_account_name),
                                        'provider', p_provider, 'currency', p_currency),
    p_reason => format('bank account %s created for business %s', v_id, p_business_id));

  RETURN jsonb_build_object('ok', true, 'bank_account_id', v_id);
END;
$function$;

REVOKE ALL ON FUNCTION public.create_bank_account(uuid,text,text,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_bank_account(uuid,text,text,text,text) TO authenticated;
