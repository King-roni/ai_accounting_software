-- =============================================================================
-- Pretest readiness fix (2026-06-01) — register income_matching issue types
-- =============================================================================
-- apply_income_match emits review_issues with
--   issue_type = 'income_matching.' || lower(p_outcome::text)
-- For the outcomes that raise a review issue, that yields:
--   income_matching.full_match            (FULL_MATCH without a reference match)
--   income_matching.partial_payment       (PARTIAL_PAYMENT)
--   income_matching.overpayment           (OVERPAYMENT)
--   income_matching.multiple_invoices_one_payment   (registered)
--   income_matching.possible_refund_or_transfer     (registered)
-- but issue_type_registry was seeded (2026-05-25) with the names
-- 'overpayment_credit_note_required' / 'invoice_lifecycle_failed' and is MISSING
-- 'full_match', 'partial_payment', 'overpayment'. So review_issues_issue_type_fkey
-- raises 23503 and the IN INCOME_MATCHING phase CRASHES whenever income fully
-- matches / partially pays / overpays an invoice (the common income path).
--
-- Register the three actually-emitted types. The INSERT in apply_income_match
-- supplies its own group/severity (NEEDS_CONFIRMATION / MEDIUM), so default_group/
-- default_severity here are just registry defaults; allowed_resolution_actions
-- drives the review-queue UI's offered actions.
-- =============================================================================

INSERT INTO public.issue_type_registry
  (issue_type, default_group, default_severity, allowed_resolution_actions,
   producing_block, plain_language_template_ref, registered_at)
VALUES
  ('income_matching.full_match',
   'NEEDS_CONFIRMATION'::public.review_issue_group_enum,
   'MEDIUM'::public.review_issue_severity_enum,
   ARRAY['CONFIRM_MATCH','REJECT_MATCH','ADD_EXPLANATION_NOTE','SEND_TO_ACCOUNTANT_REVIEW']::public.resolution_action_kind_enum[],
   'income_matching', 'review_queue.card_content_default', clock_timestamp()),
  ('income_matching.partial_payment',
   'NEEDS_CONFIRMATION'::public.review_issue_group_enum,
   'MEDIUM'::public.review_issue_severity_enum,
   ARRAY['CONFIRM_MATCH','ADD_EXPLANATION_NOTE','SEND_TO_ACCOUNTANT_REVIEW']::public.resolution_action_kind_enum[],
   'income_matching', 'review_queue.card_content_default', clock_timestamp()),
  ('income_matching.overpayment',
   'NEEDS_CONFIRMATION'::public.review_issue_group_enum,
   'MEDIUM'::public.review_issue_severity_enum,
   ARRAY['CONFIRM_MATCH','CHANGE_TAG','ADD_EXPLANATION_NOTE','SEND_TO_ACCOUNTANT_REVIEW']::public.resolution_action_kind_enum[],
   'income_matching', 'review_queue.card_content_default', clock_timestamp())
ON CONFLICT (issue_type) DO NOTHING;
