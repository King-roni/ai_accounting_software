-- B03·P08 Part 1: tool_invocation_status enum extension (deferred visibility split)
ALTER TYPE public.tool_invocation_status_enum ADD VALUE IF NOT EXISTS 'SKIPPED';
