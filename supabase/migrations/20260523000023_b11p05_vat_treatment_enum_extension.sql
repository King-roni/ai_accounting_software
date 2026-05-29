-- B11·P05 part 1 of 2 — extend vat_treatment_enum with the 3 missing
-- spec-canonical values (DOMESTIC_CYPRUS_VAT, EXEMPT, NO_VAT).
-- Split because ALTER TYPE ADD VALUE is not visible inside the same transaction
-- (deferred visibility). Same pattern as B09·P10 / B10·P10 / B11·P02.
--
-- Existing legacy DB values (DOMESTIC_STANDARD, DOMESTIC_REDUCED, DOMESTIC_ZERO)
-- stay in the enum because Postgres can't drop enum values without rebuilding
-- the type — they're modelling rate, which is a separate concern from treatment
-- per the architecture doc. The B11·P05 classifier writes only the canonical 8.
-- Existing B11·P02 seed mapping rules referencing the legacy values continue
-- to work; future Block 13 invoice-rate logic owns rate modelling.

ALTER TYPE public.vat_treatment_enum ADD VALUE IF NOT EXISTS 'DOMESTIC_CYPRUS_VAT';
ALTER TYPE public.vat_treatment_enum ADD VALUE IF NOT EXISTS 'EXEMPT';
ALTER TYPE public.vat_treatment_enum ADD VALUE IF NOT EXISTS 'NO_VAT';
