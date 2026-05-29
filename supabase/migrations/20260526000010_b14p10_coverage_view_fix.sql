-- B14·P10 fix-up: the original coverage view did a `FROM registry, LATERAL
-- unnest(covers_phases)` which multiplied rows by phases, causing
-- count(*) in the GROUP BY to count (fixture × phase) pairs rather than
-- distinct fixtures. Fixtures that cover multiple B14 phases (e.g.,
-- resolution_confirm_match covering both P04 and P08) inflate
-- fixture_count. Switching to a plain GROUP BY over the registry and a
-- subquery for distinct_phases gives the right per-category count.

DROP VIEW IF EXISTS public.v_review_queue_fixture_coverage;

CREATE VIEW public.v_review_queue_fixture_coverage AS
  SELECT r.category,
         count(*)                                                  AS fixture_count,
         (SELECT array_agg(DISTINCT p ORDER BY p)
            FROM public.review_queue_fixture_registry r2,
                 LATERAL unnest(r2.covers_phases) AS p
           WHERE r2.category = r.category)                          AS distinct_phases,
         count(*) FILTER (WHERE 'P02' = ANY(r.covers_phases))       AS covers_p02,
         count(*) FILTER (WHERE 'P03' = ANY(r.covers_phases))       AS covers_p03,
         count(*) FILTER (WHERE 'P04' = ANY(r.covers_phases))       AS covers_p04,
         count(*) FILTER (WHERE 'P05' = ANY(r.covers_phases))       AS covers_p05,
         count(*) FILTER (WHERE 'P06' = ANY(r.covers_phases))       AS covers_p06,
         count(*) FILTER (WHERE 'P07' = ANY(r.covers_phases))       AS covers_p07,
         count(*) FILTER (WHERE 'P08' = ANY(r.covers_phases))       AS covers_p08,
         count(*) FILTER (WHERE 'P09' = ANY(r.covers_phases))       AS covers_p09
    FROM public.review_queue_fixture_registry r
   GROUP BY r.category
   ORDER BY r.category;

COMMENT ON VIEW public.v_review_queue_fixture_coverage IS
  'B14·P10 coverage rollup: per-category fixture_count + per-B14-phase coverage counts (one row per fixture).';
