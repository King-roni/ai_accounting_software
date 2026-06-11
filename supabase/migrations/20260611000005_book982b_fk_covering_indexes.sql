-- =============================================================================
-- BOOK-982 (b) — add covering indexes for unindexed foreign keys.
-- =============================================================================
-- The performance advisor flags ~104 foreign keys with no covering index, which
-- makes referential-action checks (ON DELETE/UPDATE) and FK joins do sequential
-- scans. Add a btree index on the FK column(s) for every FK whose columns are not
-- already the leading prefix of some index. Idempotent (CREATE INDEX IF NOT EXISTS);
-- only covers app schemas.
-- =============================================================================

DO $$
DECLARE r record; v_name text; v_collist text;
BEGIN
  FOR r IN
    WITH fk AS (
      SELECT c.oid, c.conrelid, n.nspname AS sch, rel.relname AS tbl, c.conname, c.conkey,
             (SELECT array_agg(a.attname ORDER BY k.ord)
                FROM unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
                JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum) AS cols
      FROM pg_constraint c
      JOIN pg_class rel ON rel.oid = c.conrelid
      JOIN pg_namespace n ON n.oid = rel.relnamespace
      WHERE c.contype = 'f'
        AND n.nspname IN ('public','audit','archive','keys','analytics','secrets','auth_runtime','alerts')
    )
    SELECT sch, tbl, cols, conrelid, conkey FROM fk
    WHERE NOT EXISTS (
      SELECT 1 FROM pg_index i
      WHERE i.indrelid = fk.conrelid
        AND (string_to_array(i.indkey::text, ' ')::int2[])[1:cardinality(fk.conkey)] = fk.conkey::int2[]
    )
  LOOP
    v_name := left('ix_' || r.tbl || '_' || array_to_string(r.cols, '_'), 63);
    v_collist := (SELECT string_agg(quote_ident(col), ', ') FROM unnest(r.cols) col);
    EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I.%I (%s)', v_name, r.sch, r.tbl, v_collist);
  END LOOP;
END $$;
