-- =============================================================================
-- BOOK-981 — dashboard "Recurring Revenue" card actually shows vendor SPEND.
-- =============================================================================
-- The subscription_recurring_totals card is rendered from recurring_vendor_memory
-- (vendor_count, suppliers, total_monthly, expense colour, "N recurring vendors
-- · per month") — i.e. the business's recurring EXPENSE/subscription spend, the
-- same data as the /subscriptions page. But its dashboard_card_definitions
-- display_name was "Recurring Revenue" and description "MRR / ARR derived from
-- recurring invoice templates" — left over from an earlier MRR design. A user
-- therefore read recurring expenses (e.g. €1,503.76 of office rent + cloud +
-- software) as recurring income. Relabel the card to match the data it shows.
-- =============================================================================

UPDATE public.dashboard_card_definitions
   SET display_name = 'Recurring Spend',
       description  = 'Recurring vendor and subscription spend the system tracks each month.'
 WHERE card_id = 'subscription_recurring_totals';
