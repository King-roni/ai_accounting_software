-- B05·P10 Security Alerting (Internal)
-- ============================================================================
-- The DB-side primitives for the security alerting layer. Actual evaluator
-- worker (periodic cron that runs SQL queries against audit_events per rule
-- definition), Slack/PagerDuty routing, on-call rotation, and digest cron all
-- live at the API/worker layer. This phase ships:
--   * alert_rules configuration table + 9 built-in rules
--   * alerts lifecycle table (FIRED → ACKNOWLEDGED → RESOLVED)
--   * fire_alert with deduplication (rule + subject within dedup_window)
--   * acknowledge / resolve / add_rule / update_rule / disable_rule RPCs
--   * 7 audit actions per spec
--   * SECURITY_ALERTING_MANAGE sensitive surface for rule operations
--
-- Routing hint: CRITICAL alerts include `route: 'page_on_call'` in the audit
-- payload + `alert.severity` field; evaluator/worker consumes audits + routes
-- to Slack/PagerDuty per the alert routing sub-doc.
--
-- INTERNAL-ONLY per Stage 1 decision — no user-facing emissions in MVP.
-- ============================================================================

-- ---- subject_type extension --------------------------------------------------
ALTER TYPE audit.subject_type_enum ADD VALUE IF NOT EXISTS 'SECURITY_ALERT';

-- ---- alerts schema + enums ---------------------------------------------------
CREATE SCHEMA IF NOT EXISTS alerts;

CREATE TYPE alerts.severity_enum     AS ENUM ('CRITICAL','HIGH','MEDIUM','LOW');
CREATE TYPE alerts.alert_status_enum AS ENUM ('FIRED','ACKNOWLEDGED','RESOLVED');
CREATE TYPE alerts.subject_kind_enum AS ENUM ('ACTOR','BUSINESS','SYSTEM');

-- ---- SECURITY_ALERTING_MANAGE sensitive surface -----------------------------
INSERT INTO auth_runtime.sensitive_surfaces (surface, step_up_window, description)
VALUES ('SECURITY_ALERTING_MANAGE', '5 minutes',
        'Manage alert rules (add/update/disable) — internal ops only (B05·P10)')
ON CONFLICT (surface) DO NOTHING;

-- ---- alerts.alert_rules ------------------------------------------------------
CREATE TABLE alerts.alert_rules (
  id              uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  name            text NOT NULL UNIQUE,
  severity        alerts.severity_enum NOT NULL,
  dedup_window    interval NOT NULL DEFAULT '15 minutes'::interval,
  enabled         boolean NOT NULL DEFAULT true,
  description     text NOT NULL,
  evaluator_hint  jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT alert_rules_dedup_positive_chk CHECK (dedup_window > '0'::interval),
  CONSTRAINT alert_rules_name_nonempty_chk  CHECK (length(btrim(name)) > 0)
);

CREATE INDEX idx_alert_rules_enabled ON alerts.alert_rules (enabled) WHERE enabled;
CREATE INDEX idx_alert_rules_severity ON alerts.alert_rules (severity);

-- ---- alerts.alerts -----------------------------------------------------------
CREATE TABLE alerts.alerts (
  id                   uuid PRIMARY KEY DEFAULT public.gen_uuid_v7(),
  rule_id              uuid NOT NULL REFERENCES alerts.alert_rules(id) ON DELETE RESTRICT,
  severity             alerts.severity_enum NOT NULL,
  subject_kind         alerts.subject_kind_enum NOT NULL,
  subject_id           uuid,  -- NULL for SYSTEM subject
  subject_descriptor   text,
  payload              jsonb NOT NULL DEFAULT '{}'::jsonb,
  status               alerts.alert_status_enum NOT NULL DEFAULT 'FIRED',
  dedup_count          int NOT NULL DEFAULT 1,
  fired_at             timestamptz NOT NULL DEFAULT clock_timestamp(),
  last_fired_at        timestamptz NOT NULL DEFAULT clock_timestamp(),
  acknowledged_at      timestamptz,
  acknowledged_by      uuid REFERENCES public.users(id),
  resolved_at          timestamptz,
  resolved_by          uuid REFERENCES public.users(id),
  resolution_notes     text,
  CONSTRAINT alerts_dedup_count_positive_chk CHECK (dedup_count >= 1),
  CONSTRAINT alerts_subject_consistency_chk  CHECK (
    (subject_kind = 'SYSTEM' AND subject_id IS NULL)
    OR
    (subject_kind <> 'SYSTEM' AND subject_id IS NOT NULL)
  ),
  CONSTRAINT alerts_status_consistency_chk CHECK (
    (status = 'FIRED'        AND acknowledged_at IS NULL AND resolved_at IS NULL)
    OR
    (status = 'ACKNOWLEDGED' AND acknowledged_at IS NOT NULL AND acknowledged_by IS NOT NULL AND resolved_at IS NULL)
    OR
    (status = 'RESOLVED'     AND resolved_at IS NOT NULL AND resolved_by IS NOT NULL AND resolution_notes IS NOT NULL)
  )
);

CREATE INDEX idx_alerts_rule_subject_fired ON alerts.alerts (rule_id, subject_kind, subject_id, fired_at DESC);
CREATE INDEX idx_alerts_status              ON alerts.alerts (status);
CREATE INDEX idx_alerts_severity            ON alerts.alerts (severity);
CREATE INDEX idx_alerts_fired_at            ON alerts.alerts (fired_at DESC);
CREATE INDEX idx_alerts_subject             ON alerts.alerts (subject_kind, subject_id) WHERE subject_id IS NOT NULL;

-- ---- RLS — internal-only ---------------------------------------------------
ALTER TABLE alerts.alert_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE alerts.alert_rules FORCE  ROW LEVEL SECURITY;
ALTER TABLE alerts.alerts      ENABLE ROW LEVEL SECURITY;
ALTER TABLE alerts.alerts      FORCE  ROW LEVEL SECURITY;

CREATE POLICY alert_rules_no_authenticated ON alerts.alert_rules AS RESTRICTIVE FOR ALL TO authenticated USING (false) WITH CHECK (false);
CREATE POLICY alerts_no_authenticated      ON alerts.alerts      AS RESTRICTIVE FOR ALL TO authenticated USING (false) WITH CHECK (false);

GRANT USAGE  ON SCHEMA alerts TO service_role;
GRANT SELECT ON alerts.alert_rules, alerts.alerts TO service_role;

-- ---- 9 built-in rules per spec -----------------------------------------------
INSERT INTO alerts.alert_rules (name, severity, dedup_window, description, evaluator_hint) VALUES
  ('cross_tenant_access_attempts', 'HIGH',     '1 hour',     'Any audit event with cross_tenant=true. Repeated within 1h same actor escalates to CRITICAL (escalation handled by evaluator).', jsonb_build_object('source_action', 'ACCESS_DENIED', 'filter', jsonb_build_object('cross_tenant', true), 'escalation_window_minutes', 60, 'escalation_count', 3, 'escalation_severity', 'CRITICAL')),
  ('repeated_access_denials',      'MEDIUM',   '30 minutes', 'N ACCESS_DENIED events from one actor within M minutes. Default N=10 M=15min.', jsonb_build_object('source_action', 'ACCESS_DENIED', 'threshold_count', 10, 'threshold_window_minutes', 15)),
  ('decision_throws',              'CRITICAL', '5 minutes',  'ACCESS_DECISION_THREW — runtime bug in can_perform.', jsonb_build_object('source_action', 'ACCESS_DECISION_THREW', 'route', 'page_on_call')),
  ('chain_verification_failures',  'CRITICAL', '5 minutes',  'CHAIN_VERIFICATION_FAILED — audit hash chain tampering or corruption.', jsonb_build_object('source_action', 'CHAIN_VERIFICATION_FAILED', 'route', 'page_on_call')),
  ('failed_login_spikes',          'HIGH',     '15 minutes', 'N LOGIN_FAILED events within M minutes — potential password-spray attack. Default N=20 M=10min.', jsonb_build_object('source_action', 'LOGIN_FAILED', 'threshold_count', 20, 'threshold_window_minutes', 10)),
  ('object_lock_violations',       'CRITICAL', '5 minutes',  'OBJECT_LOCK_VIOLATION_DETECTED from archive bucket — Object Lock retention violated.', jsonb_build_object('source_action', 'OBJECT_LOCK_VIOLATION_DETECTED', 'route', 'page_on_call')),
  ('restore_verification_failures','CRITICAL', '5 minutes',  'RESTORE_VERIFICATION_FAILED — restored data integrity violation.', jsonb_build_object('source_action', 'RESTORE_VERIFICATION_FAILED', 'route', 'page_on_call')),
  ('secret_access_anomalies',      'MEDIUM',   '1 hour',     'High-frequency SECRET_ACCESSED for sensitive secrets, off-hours patterns. Default N=50 M=10min.', jsonb_build_object('source_action', 'SECRET_ACCESSED', 'threshold_count', 50, 'threshold_window_minutes', 10, 'off_hours', jsonb_build_array('22:00','06:00'))),
  ('backup_replication_lag_exceeded','HIGH',   '30 minutes', 'BACKUP_REPLICATION_LAG_EXCEEDED from B05·P08.', jsonb_build_object('source_action', 'BACKUP_REPLICATION_LAG_EXCEEDED'));

-- ---- internal helper: _route_hint -------------------------------------------
CREATE OR REPLACE FUNCTION alerts._route_hint(p_severity alerts.severity_enum)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_temp
AS $fn$
  SELECT CASE WHEN p_severity = 'CRITICAL' THEN 'page_on_call'
              WHEN p_severity = 'HIGH'     THEN 'security_channel'
              WHEN p_severity = 'MEDIUM'   THEN 'daily_digest'
              ELSE 'daily_digest' END;
$fn$;

-- ---- RPC: fire_alert (with deduplication) ----------------------------------
CREATE OR REPLACE FUNCTION alerts.fire_alert(
  p_rule_name          text,
  p_subject_kind       alerts.subject_kind_enum,
  p_subject_id         uuid,
  p_subject_descriptor text,
  p_payload            jsonb DEFAULT '{}'::jsonb
) RETURNS alerts.alerts
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = alerts, audit, public, pg_temp
AS $fn$
DECLARE
  v_rule       alerts.alert_rules;
  v_existing   alerts.alerts;
  v_row        alerts.alerts;
  v_route      text;
BEGIN
  IF p_rule_name IS NULL OR length(btrim(p_rule_name)) = 0 THEN
    RAISE EXCEPTION 'fire_alert: rule_name required' USING ERRCODE='22000';
  END IF;
  IF p_subject_kind IS NULL THEN
    RAISE EXCEPTION 'fire_alert: subject_kind required' USING ERRCODE='22000';
  END IF;
  IF p_subject_kind = 'SYSTEM' AND p_subject_id IS NOT NULL THEN
    RAISE EXCEPTION 'fire_alert: SYSTEM subject must not have subject_id' USING ERRCODE='22000';
  END IF;
  IF p_subject_kind <> 'SYSTEM' AND p_subject_id IS NULL THEN
    RAISE EXCEPTION 'fire_alert: % subject requires subject_id', p_subject_kind USING ERRCODE='22000';
  END IF;

  SELECT * INTO v_rule FROM alerts.alert_rules WHERE name = p_rule_name;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'fire_alert: rule % not found', p_rule_name USING ERRCODE='P0002';
  END IF;
  IF NOT v_rule.enabled THEN
    RAISE EXCEPTION 'fire_alert: rule % is disabled', p_rule_name USING ERRCODE='42501';
  END IF;

  v_route := alerts._route_hint(v_rule.severity);

  -- Dedup lookup: same rule + subject in non-RESOLVED status within window
  SELECT * INTO v_existing
    FROM alerts.alerts
   WHERE rule_id = v_rule.id
     AND subject_kind = p_subject_kind
     AND ((p_subject_id IS NULL AND subject_id IS NULL) OR subject_id = p_subject_id)
     AND status IN ('FIRED','ACKNOWLEDGED')
     AND fired_at > clock_timestamp() - v_rule.dedup_window
   ORDER BY fired_at DESC
   LIMIT 1
   FOR UPDATE;

  IF FOUND THEN
    UPDATE alerts.alerts
       SET dedup_count   = v_existing.dedup_count + 1,
           last_fired_at = clock_timestamp(),
           payload       = v_existing.payload || jsonb_build_object('last_event_payload', p_payload)
     WHERE id = v_existing.id
    RETURNING * INTO v_row;

    PERFORM audit.emit_audit(
      p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
      p_action       => 'SECURITY_ALERT_DEDUPLICATED',
      p_subject_type => 'SECURITY_ALERT'::audit.subject_type_enum,
      p_subject_id   => v_row.id,
      p_actor_system => 'alerts.fire_alert',
      p_reason       => format('alert %s deduplicated (count now %s)', v_row.id, v_row.dedup_count),
      p_after_state  => jsonb_build_object(
        'alert_id', v_row.id, 'rule_name', p_rule_name, 'severity', v_rule.severity,
        'dedup_count', v_row.dedup_count, 'subject_kind', p_subject_kind, 'subject_id', p_subject_id
      )
    );
    RETURN v_row;
  END IF;

  -- New alert
  INSERT INTO alerts.alerts (
    rule_id, severity, subject_kind, subject_id, subject_descriptor, payload, status, fired_at, last_fired_at
  ) VALUES (
    v_rule.id, v_rule.severity, p_subject_kind, p_subject_id, p_subject_descriptor,
    COALESCE(p_payload, '{}'::jsonb), 'FIRED', clock_timestamp(), clock_timestamp()
  )
  RETURNING * INTO v_row;

  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'SECURITY_ALERT_FIRED',
    p_subject_type => 'SECURITY_ALERT'::audit.subject_type_enum,
    p_subject_id   => v_row.id,
    p_actor_system => 'alerts.fire_alert',
    p_reason       => format('%s alert fired: %s (subject %s)', v_rule.severity, p_rule_name, COALESCE(p_subject_descriptor, p_subject_id::text, 'SYSTEM')),
    p_after_state  => jsonb_build_object(
      'alert_id', v_row.id,
      'rule_name', p_rule_name,
      'rule_id', v_rule.id,
      'severity', v_rule.severity,
      'subject_kind', p_subject_kind,
      'subject_id', p_subject_id,
      'subject_descriptor', p_subject_descriptor,
      'route', v_route,
      'payload', p_payload
    )
  );

  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION alerts.fire_alert(text, alerts.subject_kind_enum, uuid, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION alerts.fire_alert(text, alerts.subject_kind_enum, uuid, text, jsonb) TO service_role;

-- ---- RPC: acknowledge_alert -------------------------------------------------
CREATE OR REPLACE FUNCTION alerts.acknowledge_alert(p_alert_id uuid, p_user_id uuid)
RETURNS alerts.alerts
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = alerts, audit, public, pg_temp
AS $fn$
DECLARE v_row alerts.alerts;
BEGIN
  IF p_alert_id IS NULL THEN RAISE EXCEPTION 'acknowledge_alert: id required' USING ERRCODE='22000'; END IF;
  IF p_user_id  IS NULL THEN RAISE EXCEPTION 'acknowledge_alert: user_id required' USING ERRCODE='22000'; END IF;
  SELECT * INTO v_row FROM alerts.alerts WHERE id = p_alert_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'acknowledge_alert: % not found', p_alert_id USING ERRCODE='P0002'; END IF;
  IF v_row.status <> 'FIRED' THEN
    RAISE EXCEPTION 'acknowledge_alert: % not in FIRED (got %)', p_alert_id, v_row.status USING ERRCODE='23514';
  END IF;
  UPDATE alerts.alerts SET status='ACKNOWLEDGED', acknowledged_at=clock_timestamp(), acknowledged_by=p_user_id
   WHERE id = p_alert_id RETURNING * INTO v_row;
  PERFORM audit.emit_audit(
    p_actor_kind => 'USER'::audit.actor_kind_enum,
    p_action => 'SECURITY_ALERT_ACKNOWLEDGED',
    p_subject_type => 'SECURITY_ALERT'::audit.subject_type_enum,
    p_subject_id => v_row.id, p_actor_user_id => p_user_id,
    p_reason => format('alert %s acknowledged', p_alert_id),
    p_after_state => jsonb_build_object('alert_id', v_row.id, 'acknowledged_by', p_user_id)
  );
  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION alerts.acknowledge_alert(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION alerts.acknowledge_alert(uuid, uuid) TO service_role;

-- ---- RPC: resolve_alert -----------------------------------------------------
CREATE OR REPLACE FUNCTION alerts.resolve_alert(p_alert_id uuid, p_user_id uuid, p_resolution_notes text)
RETURNS alerts.alerts
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = alerts, audit, public, pg_temp
AS $fn$
DECLARE v_row alerts.alerts;
BEGIN
  IF p_alert_id IS NULL THEN RAISE EXCEPTION 'resolve_alert: id required' USING ERRCODE='22000'; END IF;
  IF p_user_id  IS NULL THEN RAISE EXCEPTION 'resolve_alert: user_id required' USING ERRCODE='22000'; END IF;
  IF p_resolution_notes IS NULL OR length(btrim(p_resolution_notes)) = 0 THEN
    RAISE EXCEPTION 'resolve_alert: resolution_notes required' USING ERRCODE='22000';
  END IF;
  SELECT * INTO v_row FROM alerts.alerts WHERE id = p_alert_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'resolve_alert: % not found', p_alert_id USING ERRCODE='P0002'; END IF;
  IF v_row.status = 'RESOLVED' THEN
    RAISE EXCEPTION 'resolve_alert: % already RESOLVED', p_alert_id USING ERRCODE='23514';
  END IF;
  UPDATE alerts.alerts
     SET status='RESOLVED', resolved_at=clock_timestamp(), resolved_by=p_user_id, resolution_notes=p_resolution_notes
   WHERE id = p_alert_id RETURNING * INTO v_row;
  PERFORM audit.emit_audit(
    p_actor_kind => 'USER'::audit.actor_kind_enum,
    p_action => 'SECURITY_ALERT_RESOLVED',
    p_subject_type => 'SECURITY_ALERT'::audit.subject_type_enum,
    p_subject_id => v_row.id, p_actor_user_id => p_user_id,
    p_reason => format('alert %s resolved: %s', p_alert_id, p_resolution_notes),
    p_after_state => jsonb_build_object('alert_id', v_row.id, 'resolved_by', p_user_id, 'resolution_notes', p_resolution_notes)
  );
  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION alerts.resolve_alert(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION alerts.resolve_alert(uuid, uuid, text) TO service_role;

-- ---- RPC: add_rule -----------------------------------------------------------
CREATE OR REPLACE FUNCTION alerts.add_rule(
  p_name           text,
  p_severity       alerts.severity_enum,
  p_dedup_window   interval,
  p_description    text,
  p_evaluator_hint jsonb DEFAULT '{}'::jsonb
) RETURNS alerts.alert_rules
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = alerts, audit, public, pg_temp
AS $fn$
DECLARE v_row alerts.alert_rules;
BEGIN
  IF p_name IS NULL OR length(btrim(p_name)) = 0 THEN RAISE EXCEPTION 'add_rule: name required' USING ERRCODE='22000'; END IF;
  IF p_severity IS NULL THEN RAISE EXCEPTION 'add_rule: severity required' USING ERRCODE='22000'; END IF;
  IF p_dedup_window IS NULL OR p_dedup_window <= '0'::interval THEN
    RAISE EXCEPTION 'add_rule: dedup_window must be > 0' USING ERRCODE='22000'; END IF;
  IF p_description IS NULL OR length(btrim(p_description)) = 0 THEN
    RAISE EXCEPTION 'add_rule: description required' USING ERRCODE='22000'; END IF;

  INSERT INTO alerts.alert_rules (name, severity, dedup_window, description, evaluator_hint, enabled)
  VALUES (p_name, p_severity, p_dedup_window, p_description, COALESCE(p_evaluator_hint, '{}'::jsonb), true)
  RETURNING * INTO v_row;

  PERFORM audit.emit_audit(
    p_actor_kind => 'SYSTEM'::audit.actor_kind_enum,
    p_action => 'ALERT_RULE_ADDED',
    p_subject_type => 'SECURITY_ALERT'::audit.subject_type_enum,
    p_subject_id => v_row.id, p_actor_system => 'alerts.add_rule',
    p_reason => format('alert rule %s added (%s)', p_name, p_severity),
    p_after_state => jsonb_build_object(
      'rule_id', v_row.id, 'name', p_name, 'severity', p_severity,
      'dedup_window_seconds', extract(epoch from p_dedup_window)::int,
      'evaluator_hint', v_row.evaluator_hint
    )
  );
  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION alerts.add_rule(text, alerts.severity_enum, interval, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION alerts.add_rule(text, alerts.severity_enum, interval, text, jsonb) TO service_role;

-- ---- RPC: update_rule -------------------------------------------------------
CREATE OR REPLACE FUNCTION alerts.update_rule(
  p_rule_id        uuid,
  p_severity       alerts.severity_enum DEFAULT NULL,
  p_dedup_window   interval DEFAULT NULL,
  p_description    text DEFAULT NULL,
  p_evaluator_hint jsonb DEFAULT NULL
) RETURNS alerts.alert_rules
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = alerts, audit, public, pg_temp
AS $fn$
DECLARE
  v_before alerts.alert_rules;
  v_row    alerts.alert_rules;
BEGIN
  IF p_rule_id IS NULL THEN RAISE EXCEPTION 'update_rule: id required' USING ERRCODE='22000'; END IF;
  SELECT * INTO v_before FROM alerts.alert_rules WHERE id = p_rule_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'update_rule: % not found', p_rule_id USING ERRCODE='P0002'; END IF;

  UPDATE alerts.alert_rules
     SET severity       = COALESCE(p_severity,       severity),
         dedup_window   = COALESCE(p_dedup_window,   dedup_window),
         description    = COALESCE(p_description,    description),
         evaluator_hint = COALESCE(p_evaluator_hint, evaluator_hint),
         updated_at     = clock_timestamp()
   WHERE id = p_rule_id
  RETURNING * INTO v_row;

  PERFORM audit.emit_audit(
    p_actor_kind => 'SYSTEM'::audit.actor_kind_enum,
    p_action => 'ALERT_RULE_UPDATED',
    p_subject_type => 'SECURITY_ALERT'::audit.subject_type_enum,
    p_subject_id => v_row.id, p_actor_system => 'alerts.update_rule',
    p_reason => format('alert rule %s updated', v_row.name),
    p_before_state => jsonb_build_object(
      'severity', v_before.severity,
      'dedup_window_seconds', extract(epoch from v_before.dedup_window)::int,
      'description', v_before.description,
      'evaluator_hint', v_before.evaluator_hint
    ),
    p_after_state => jsonb_build_object(
      'rule_id', v_row.id, 'name', v_row.name,
      'severity', v_row.severity,
      'dedup_window_seconds', extract(epoch from v_row.dedup_window)::int,
      'description', v_row.description,
      'evaluator_hint', v_row.evaluator_hint
    )
  );
  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION alerts.update_rule(uuid, alerts.severity_enum, interval, text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION alerts.update_rule(uuid, alerts.severity_enum, interval, text, jsonb) TO service_role;

-- ---- RPC: disable_rule ------------------------------------------------------
CREATE OR REPLACE FUNCTION alerts.disable_rule(p_rule_id uuid)
RETURNS alerts.alert_rules
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = alerts, audit, public, pg_temp
AS $fn$
DECLARE v_row alerts.alert_rules;
BEGIN
  IF p_rule_id IS NULL THEN RAISE EXCEPTION 'disable_rule: id required' USING ERRCODE='22000'; END IF;
  UPDATE alerts.alert_rules SET enabled=false, updated_at=clock_timestamp()
   WHERE id = p_rule_id RETURNING * INTO v_row;
  IF NOT FOUND THEN RAISE EXCEPTION 'disable_rule: % not found', p_rule_id USING ERRCODE='P0002'; END IF;
  PERFORM audit.emit_audit(
    p_actor_kind => 'SYSTEM'::audit.actor_kind_enum,
    p_action => 'ALERT_RULE_DISABLED',
    p_subject_type => 'SECURITY_ALERT'::audit.subject_type_enum,
    p_subject_id => v_row.id, p_actor_system => 'alerts.disable_rule',
    p_reason => format('alert rule %s disabled', v_row.name),
    p_after_state => jsonb_build_object('rule_id', v_row.id, 'name', v_row.name, 'enabled', false)
  );
  RETURN v_row;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION alerts.disable_rule(uuid) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION alerts.disable_rule(uuid) TO service_role;

-- ---- bootstrap audit event --------------------------------------------------
DO $bootstrap$
BEGIN
  PERFORM audit.emit_audit(
    p_actor_kind   => 'SYSTEM'::audit.actor_kind_enum,
    p_action       => 'VAULT_INITIALIZED',
    p_subject_type => 'AUDIT_QUERY'::audit.subject_type_enum,
    p_actor_system => 'b05p10-migration',
    p_reason       => 'security alerting (internal) online — alerts.{alert_rules, alerts} + 6 RPCs + 9 built-in rules + SECURITY_ALERTING_MANAGE sensitive surface. BLOCK 05 COMPLETE.'
  );
END
$bootstrap$;

COMMENT ON SCHEMA alerts IS
'B05·P10 security alerting (internal-only). alert_rules drives the evaluator worker; alerts records firings with dedup. Routing (Slack/PagerDuty/digest) is API/worker-layer; DB embeds route hint in audit payload.';

COMMENT ON TABLE alerts.alert_rules IS
'B05·P10 rule configuration. evaluator_hint jsonb carries thresholds/filters/route knobs consumed by the API/worker evaluator. Bootstrap rows cover the 9 built-in MVP rules.';

COMMENT ON TABLE alerts.alerts IS
'B05·P10 alert lifecycle: FIRED → ACKNOWLEDGED → RESOLVED. dedup_count tracks rolled-up identical events within rule.dedup_window. Subject XOR enforces SYSTEM iff subject_id NULL.';

COMMENT ON FUNCTION alerts.fire_alert(text, alerts.subject_kind_enum, uuid, text, jsonb) IS
'B05·P10 alert chokepoint. Deduplicates against (rule, subject) within rule.dedup_window for non-RESOLVED alerts → increments dedup_count + emits SECURITY_ALERT_DEDUPLICATED. New alerts emit SECURITY_ALERT_FIRED with route hint (page_on_call / security_channel / daily_digest) by severity. Disabled or unknown rules RAISE.';
