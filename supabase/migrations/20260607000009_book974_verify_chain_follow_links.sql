-- =============================================================================
-- BOOK-974 — verify audit chain by following the hash linkage, not event_id.
-- =============================================================================
-- audit._verify_chain_walk walked events ORDER BY event_id ASC and assumed
-- event_id order == chain order. Under concurrent emit_audit calls the event_id
-- sequence can be assigned out of order vs the prev_event_hash linkage, so the
-- walker reported a false "prev_event_hash_mismatch" on an intact chain
-- (verified independently: 0 forks, single genesis, single tip per org).
--
-- Fix: follow the prev_event_hash linkage from genesis. Because there are no
-- forks (each prev_event_hash is referenced by at most one event), each step has
-- a unique successor. A real break now surfaces as event_hash_mismatch (a
-- tampered/forged event) or chain_incomplete_unreachable_events (a gap or a
-- tamper that splits the chain so not every event is reachable from genesis).
-- A supporting index keeps the per-step lookup fast.
-- =============================================================================

CREATE INDEX IF NOT EXISTS ix_audit_events_org_prevhash
  ON audit.audit_events (organization_id, prev_event_hash);

CREATE OR REPLACE FUNCTION audit._verify_chain_walk(p_chain_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'audit', 'public', 'pg_temp'
AS $function$
DECLARE
  v_rec            record;
  v_prev_hash      text := repeat('0', 64);
  v_canonical      text;
  v_recomputed     text;
  v_break_event_id bigint := NULL;
  v_break_reason   text   := NULL;
  v_count          integer := 0;
  v_total          integer;
  v_mismatched     jsonb := '[]'::jsonb;
  v_checkpoint     record;
  SYSTEM_CHAIN_ID constant uuid := '00000000-0000-0000-0000-000000000000';
BEGIN
  SELECT count(*) INTO v_total FROM audit.audit_events
   WHERE (organization_id = p_chain_id
          OR (p_chain_id = SYSTEM_CHAIN_ID AND organization_id IS NULL));

  -- Follow the prev_event_hash linkage from genesis (BOOK-974).
  LOOP
    SELECT * INTO v_rec FROM audit.audit_events
     WHERE (organization_id = p_chain_id
            OR (p_chain_id = SYSTEM_CHAIN_ID AND organization_id IS NULL))
       AND prev_event_hash = v_prev_hash
     LIMIT 1;
    EXIT WHEN NOT FOUND;

    v_count := v_count + 1;
    EXIT WHEN v_count > v_total;  -- safety bound (cannot exceed total events)

    v_canonical := audit.canonical_event_payload(
      p_event_id        => v_rec.event_id,
      p_occurred_at     => v_rec.occurred_at,
      p_actor_kind      => v_rec.actor_kind,
      p_actor_user_id   => v_rec.actor_user_id,
      p_actor_role      => v_rec.actor_role,
      p_actor_session_id=> v_rec.actor_session_id,
      p_actor_system    => v_rec.actor_system,
      p_organization_id => v_rec.organization_id,
      p_business_id     => v_rec.business_id,
      p_subject_type    => v_rec.subject_type,
      p_subject_id      => v_rec.subject_id,
      p_action          => v_rec.action,
      p_before_state    => v_rec.before_state,
      p_after_state     => v_rec.after_state,
      p_reason          => v_rec.reason,
      p_request_context => v_rec.request_context
    );
    v_recomputed := public.hash_chain_append(v_prev_hash, v_canonical);
    IF v_recomputed IS DISTINCT FROM v_rec.event_hash THEN
      v_break_event_id := v_rec.event_id;
      v_break_reason   := 'event_hash_mismatch';
      EXIT;
    END IF;
    v_prev_hash := v_rec.event_hash;
  END LOOP;

  -- Not every event was reachable from genesis ⇒ a gap or a tamper split the chain.
  IF v_break_event_id IS NULL AND v_count <> v_total THEN
    v_break_reason := 'chain_incomplete_unreachable_events';
  END IF;

  IF v_break_event_id IS NULL AND v_break_reason IS NULL THEN
    FOR v_checkpoint IN
      SELECT cp.id          AS checkpoint_id,
             cp.event_id    AS checkpoint_event_id,
             cp.event_hash  AS stored_hash,
             ev.event_hash  AS actual_hash
        FROM audit.chain_checkpoints cp
        LEFT JOIN audit.audit_events ev ON ev.event_id = cp.event_id
       WHERE cp.chain_id = p_chain_id
       ORDER BY cp.event_id ASC
    LOOP
      IF v_checkpoint.stored_hash IS DISTINCT FROM v_checkpoint.actual_hash THEN
        v_mismatched := v_mismatched || jsonb_build_object(
          'checkpoint_id', v_checkpoint.checkpoint_id,
          'event_id',      v_checkpoint.checkpoint_event_id,
          'stored_hash',   v_checkpoint.stored_hash,
          'actual_hash',   v_checkpoint.actual_hash
        );
      END IF;
    END LOOP;
  END IF;

  RETURN jsonb_build_object(
    'chain_id',               p_chain_id,
    'verified',               (v_break_event_id IS NULL AND v_break_reason IS NULL
                               AND jsonb_array_length(v_mismatched) = 0),
    'events_walked',          v_count,
    'events_total',           v_total,
    'break_at_event_id',      v_break_event_id,
    'break_reason',           v_break_reason,
    'mismatched_checkpoints', v_mismatched
  );
END;
$function$;
