# Component Library — Variant Catalog

**Category:** Reference data · **Owning block:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 2)

**Block reference:** Block 16, Phase 07 (dashboard UI component system).

**Purpose:** Documents the complete variant matrix for the 8 core UI components. For each component, this catalog specifies the supported `variant × size × state × theme` combinations, token references, and constraints. Implementations that deviate from this matrix require a decisions-log amendment. This catalog is the binding contract between design and engineering for the component library.

---

## Matrix structure

Each component entry follows this structure:

- **Variants** — the named visual/semantic types within the component
- **Sizes** — the dimensional presets
- **States** — the interaction or data states that alter appearance
- **Themes** — light/dark support
- **Token references** — which design token files apply
- **Notes** — constraints, anti-patterns, or context-specific rules

Unsupported combinations are marked `—`. A combination marked `—` must not be implemented; if the use case arises, open a decisions-log amendment to add it explicitly.

---

## 1. Button

**Variants:** Primary · Secondary · Ghost · Destructive

**Sizes:** `sm` (32px height) · `md` (40px height) · `lg` (48px height)

**States:** `default` · `hover` · `active` · `disabled` · `loading`

**Themes:** light · dark

| Variant | sm | md | lg | Notes |
|---|---|---|---|---|
| Primary | all states | all states | all states | High-emphasis action. One Primary button per view section. |
| Secondary | all states | all states | all states | Medium-emphasis. Used for secondary confirmations. |
| Ghost | all states | all states | — | Low-emphasis inline action. `lg` Ghost is not supported. |
| Destructive | — | all states | — | Irreversible actions only (void, delete, cancel). Always paired with a confirmation modal before executing. `sm` and `lg` Destructive are not supported. |

**Loading state:** The loading state replaces the button label with a spinner icon and disables pointer events. The button width is preserved at its default width to prevent layout shift. Loading state is used for async actions (export requests, pack sends, finalization submit).

**Disabled state:** `opacity: 0.4` applied via the `--button-disabled-opacity` token. Disabled buttons must carry an accessible `aria-disabled="true"` attribute and a tooltip explaining the disable reason.

**Token references:** `severity_color_tokens.md` (Destructive variant uses `--color-severity-blocking`), `design_token_z_index_reference.md` (not applicable to Button).

---

## 2. Badge / Chip

**Variants:** severity · status · neutral

**Sizes:** `sm` · `md`

**States:** `default` · `with-dismiss-icon`

**Themes:** light · dark

### Severity variant

Maps to the four severity levels in the system-wide severity enum. Used on review issues, alert cards, and audit log entries.

| Severity level | Background token | Text token |
|---|---|---|
| `BLOCKING` | `--color-severity-blocking-bg` | `--color-severity-blocking-text` |
| `HIGH` | `--color-severity-high-bg` | `--color-severity-high-text` |
| `MEDIUM` | `--color-severity-medium-bg` | `--color-severity-medium-text` |
| `LOW` | `--color-severity-low-bg` | `--color-severity-low-text` |

Do not use ad-hoc colors for severity badges. All severity-to-color mappings must reference `severity_color_tokens.md`. The `BLOCKING` token maps to a red-family value; `HIGH` to orange; `MEDIUM` to yellow; `LOW` to neutral-secondary. Exact hex values are in the token file.

### Status variant

Maps to values from `run_status_enum`. Used on workflow run cards, run history tables, and the finalization progress stepper.

| Status | Display label | Color family |
|---|---|---|
| `CREATED` | Created | Neutral |
| `RUNNING` | Running | Blue |
| `PAUSED` | Paused | Yellow |
| `REVIEW_HOLD` | Review hold | Orange |
| `AWAITING_APPROVAL` | Awaiting approval | Purple |
| `FINALIZING` | Finalizing | Blue (animated pulse) |
| `FINALIZED` | Finalized | Green |
| `FAILED` | Failed | Red |
| `CANCELLED` | Cancelled | Neutral-muted |
| `COMPENSATING` | Compensating | Orange (animated pulse) |

`FINALIZING` and `COMPENSATING` use an animated pulse treatment to signal in-progress system activity. The animation is CSS-only (no JS timers); it must respect `prefers-reduced-motion`.

### Neutral variant

Used for non-semantic labels (format names, period labels, tags). Uses `--color-neutral-badge-bg` and `--color-neutral-badge-text`.

**With-dismiss-icon state:** Adds an `×` icon on the right side. Used in multi-select filters and tag editors. The dismiss icon triggers an `onDismiss` callback; it does not alter the badge's visual variant.

**Token references:** `severity_color_tokens.md` (severity variant), `design_token_z_index_reference.md` (not applicable to Badge).

---

## 3. Card

**Variants:** issue-card · dashboard-card · invoice-card

**Sizes:** `compact` · `standard` · `expanded`

**States:** `default` · `hover` · `selected` · `loading`

**Themes:** light · dark

### issue-card

Used in the review queue. Displays issue type, severity badge, transaction reference, and action buttons. The card's left border color reflects the severity level using `severity_color_tokens.md`.

| Size | Use context |
|---|---|
| `compact` | Bulk-action list view (all fields except detail text) |
| `standard` | Default queue view |
| `expanded` | Drill-down view with full context, linked documents, and audit trail |

`selected` state applies a border-color change using `--color-card-selected-border` and a subtle background shift. Selected state is only supported on `compact` and `standard` sizes; `expanded` cards are always single-selected by navigation, not multi-selected.

### dashboard-card

Used for KPI tiles, chart containers, and analytics summary blocks on the main dashboard.

| Size | Use context |
|---|---|
| `compact` | Secondary metrics (e.g., unmatched count, pending review count) |
| `standard` | Primary KPI tiles (e.g., total revenue, VAT liability) |
| `expanded` | Chart containers with title, chart area, and footer legend |

`loading` state: the card body is replaced by a skeleton placeholder using `--color-skeleton-base` and `--color-skeleton-highlight`. The skeleton animation must respect `prefers-reduced-motion`. The card header (title) remains visible during loading.

### invoice-card

Used in the IN workflow invoice list. Displays invoice number, client, amount, status badge, and due date.

| Size | Supported states |
|---|---|
| `compact` | `default`, `hover` |
| `standard` | `default`, `hover`, `selected` |
| `expanded` | — (invoice detail uses a dedicated page layout, not a card) |

**Token references:** `severity_color_tokens.md` (issue-card border colors), `design_token_z_index_reference.md` (not applicable to Card at default z-level; `expanded` cards in overlay contexts use `--z-modal-backdrop - 1`).

---

## 4. Modal

**Variants:** confirmation · step-up-mfa · form · destructive-confirm

**Sizes:** `sm` (400px width) · `md` (600px width) · `lg` (800px width)

**States:** `open` · `closing` · `loading`

**Themes:** light · dark

| Variant | Size | Notes |
|---|---|---|
| `confirmation` | `sm` | Yes/No confirmations for low-stakes actions. Two-button footer (primary + secondary). |
| `step-up-mfa` | `sm` | MFA challenge dialog. Fixed layout; the TOTP input is the only interactive element. Cannot be dismissed by clicking the backdrop. |
| `form` | `md` or `lg` | Configuration forms (accountant pack settings, custom report builder). Footer has Save + Cancel. |
| `destructive-confirm` | `sm` | Irreversible action confirmation (void invoice, cancel run, delete configuration). Destructive button is visually distinct (red). Requires the user to type a confirmation phrase for BLOCKING-severity actions. |

**Closing state:** Modals use a 150ms fade-out transition. The `closing` state is set when the dismiss action fires; the modal is removed from the DOM after the transition completes. This prevents layout flicker on slow paint paths.

**Loading state:** The modal footer's primary action button enters `loading` state; the form or content area is overlaid with a semi-transparent mask. The mask prevents interaction while the async action completes. The modal cannot be dismissed during `loading` state.

**Backdrop:** Click-to-dismiss is enabled for `confirmation` and `form` variants. Disabled for `step-up-mfa` and `destructive-confirm` (these require explicit user action to proceed or cancel).

**Focus management:** On open, focus is placed on the first focusable element in the modal body. On close, focus returns to the trigger element. Focus trap is active while the modal is open.

**Token references:** `design_token_z_index_reference.md` — modals use `--z-modal` (value defined in the token file). Backdrop uses `--z-modal-backdrop`. `severity_color_tokens.md` — `destructive-confirm` footer button uses `--color-severity-blocking`.

---

## 5. Toast

**Variants:** success · error · warning · info

**Sizes:** fixed 320px width (all variants)

**States:** `entering` · `visible` · `exiting`

**Themes:** light · dark

**Position:** bottom-right of the viewport. Toasts stack vertically with 8px gap; newest toast appears at the top of the stack. Maximum 5 toasts displayed simultaneously; older toasts are removed FIFO when the limit is exceeded.

| Variant | Use case | Auto-dismiss duration |
|---|---|---|
| `success` | Action completed (export ready, pack sent, config saved) | 5 seconds |
| `error` | Action failed (export failed, pack delivery failed, MFA failed) | No auto-dismiss — user must explicitly dismiss |
| `warning` | Non-blocking advisory (approaching storage limit, TTL expiring soon) | 8 seconds |
| `info` | Informational (background job queued, notification received) | 5 seconds |

**Export completion exception:** The `success` toast for async export completion does NOT auto-dismiss (overrides the 5-second default). The user must dismiss it manually, since the toast contains the "Download" action button for a time-limited signed URL.

**Entering state:** 200ms slide-up and fade-in from bottom-right. **Exiting state:** 150ms fade-out. Both must respect `prefers-reduced-motion` (instant show/hide with no animation when the media query matches).

**Action buttons:** Toasts may carry one optional action button (e.g., "Download", "Retry", "View"). The action button is `sm` Ghost variant. A second action is not supported in the Toast component; use a Modal instead.

**Token references:** `severity_color_tokens.md` — the `error` variant uses `--color-severity-high-bg` and `--color-severity-high-text`. The `warning` variant uses `--color-severity-medium-bg`. `design_token_z_index_reference.md` — toasts use `--z-toast`, which is above `--z-modal` to ensure visibility over open modals.

---

## 6. Input

**Variants:** text · number · date · select · multi-select

**Sizes:** `sm` (32px height) · `md` (40px height)

**States:** `default` · `focus` · `error` · `disabled` · `read-only`

**Themes:** light · dark

| Variant | sm | md | Notes |
|---|---|---|---|
| `text` | both states | both states | Single-line text. Multi-line text uses `textarea` (not this component). |
| `number` | both states | both states | Numeric input. Currency fields use `numeric` subtype with minor-unit display formatting (see `data_layer_conventions_policy.md`). |
| `date` | — | both states | Date picker with calendar popover. `sm` date input is not supported (insufficient width for the full date format). |
| `select` | — | both states | Single-select dropdown. `sm` select is not supported. |
| `multi-select` | — | both states | Multi-select with chip display. Each selected item renders as a neutral Badge/Chip with dismiss icon. `sm` multi-select is not supported. |

**Error state:** Adds a red border using `--color-input-error-border` and displays an error message below the field in `--color-input-error-text`. Error messages are concise (< 80 characters). The error state is not the same as a form-level error summary; per-field inline errors are preferred.

**Read-only state:** The field is styled distinctly from `disabled` — read-only fields use `--color-input-readonly-bg` (slightly off-white/off-dark) and do not grey out. The value is selectable and copyable. Used for pack configuration on mobile (all fields enter `read-only` state).

**Disabled state:** `opacity: 0.5`, pointer-events none, `aria-disabled="true"`. Use `read-only` instead of `disabled` when the value should be visible and copyable.

**Token references:** `severity_color_tokens.md` (error state border and text colors). `design_token_z_index_reference.md` — select and date pickers' popover layers use `--z-popover`.

---

## 7. Table

**Variants:** data-table · audit-log-table · ledger-table

**Sizes:** `compact` · `standard`

**States:** `loading` · `empty` · `populated` · `sorted`

**Themes:** light · dark

### data-table

General-purpose tabular display. Used for: invoice list, transaction list, match report, client list, recent exports.

- `compact`: 36px row height. No row hover highlight. Used when row density is more important than readability.
- `standard`: 48px row height. Row hover highlight using `--color-table-row-hover`.

### audit-log-table

Specialised for audit log display. Fixed columns: timestamp, event type, actor, subject, severity badge, chain status.

- Always `standard` size only — `compact` is not supported for audit-log-table (readability requirement for forensic use).
- `sorted` state: the active sort column header shows a directional arrow icon. Default sort is `event_time DESC`.

### ledger-table

Specialised for ledger entry display. Fixed columns: date, counterparty, debit account, credit account, amount (EUR), VAT treatment, locked indicator.

- Both `compact` and `standard` sizes supported.
- The `locked` column uses a lock icon badge; locked rows have a subtle background tint using `--color-ledger-locked-row-bg` to distinguish them from editable rows.

**Loading state:** Skeleton rows replace the data rows. The column headers remain visible. Skeleton row count matches the last-known row count (or 10 if no prior count is available).

**Empty state:** A centred illustration and message replace the table body. Message is context-specific (e.g., "No transactions in this period" for data-table; "No audit events in this window" for audit-log-table). The empty state is not a skeleton — it signals that the query returned zero results, not that data is loading.

**Sorted state:** Applied to `populated` state. The sorted state is a sub-state, not a mutually exclusive state. A table can be `populated` + `sorted` simultaneously.

**Token references:** `severity_color_tokens.md` (audit-log-table severity badge cells, ledger-table VAT treatment cells where VAT treatment uses severity-mapped colors). `design_token_z_index_reference.md` (sticky column headers on scroll use `--z-sticky-header`).

---

## 8. Stepper

**Variants:** horizontal · vertical

**Sizes:** `standard` (only — no compact or expanded variants)

**States:** `pending` · `active` · `completed` · `error`

**Themes:** light · dark

### horizontal (invoice lifecycle)

Used on the invoice detail view to show the invoice lifecycle: Draft → Sent → Viewed → Paid (or branching states: Partially paid, Overdue, Voided, Written off).

- Each step is a labelled circle connected by a horizontal line.
- The current step (`active`) uses `--color-stepper-active-step`.
- Completed steps use a checkmark icon with `--color-stepper-completed-step`.
- Error steps (e.g., a failed PDF render) use `--color-severity-high-bg` per `severity_color_tokens.md`.
- Pending steps use `--color-stepper-pending-step`.

**Branch handling:** The invoice lifecycle stepper supports a single branch at the `active` step (e.g., "Partially paid" branches from the "Paid" step). Branch nodes are displayed below the main line. A stepper must not have more than one active branch at a time.

### vertical (finalization progress)

Used in the finalization modal to show the 5-step lock sequence progress:

1. Gate evaluation
2. Ledger lock
3. Bundle construction
4. RFC 3161 timestamping
5. Object Lock + zone promotion

Each step transitions from `pending` → `active` → `completed` or `error` as the lock sequence progresses. The vertical stepper is read-only — it reflects system state and is not interactive.

If a step enters `error` state, subsequent steps remain `pending` and the error step displays the error class label (e.g., `OBJECT_LOCK_FAILED`) in the step description. The modal transitions to showing the error runbook link.

**Accessibility:** Each step has `role="listitem"` and a screen-reader-visible label combining the step name and its current state (e.g., "Step 3: Bundle construction — completed"). Animated transitions (active step pulse) respect `prefers-reduced-motion`.

**Token references:** `severity_color_tokens.md` (`error` state uses `--color-severity-high-bg` for the step indicator). `design_token_z_index_reference.md` (not applicable — steppers do not produce layered content).

---

## Token file dependencies

| Component | `severity_color_tokens.md` | `design_token_z_index_reference.md` |
|---|---|---|
| Button | Destructive variant | — |
| Badge/Chip | Severity variant (all 4 levels) | — |
| Card | issue-card border colors | expanded overlay context |
| Modal | destructive-confirm footer button | `--z-modal`, `--z-modal-backdrop` |
| Toast | error, warning variants | `--z-toast` |
| Input | error state border and text | `--z-popover` (select/date) |
| Table | severity badge cells, VAT treatment | `--z-sticky-header` |
| Stepper | error state step indicator | — |

---

## Cross-references

- `severity_color_tokens.md` — token values for BLOCKING / HIGH / MEDIUM / LOW severity color families
- `design_token_z_index_reference.md` — `--z-modal`, `--z-modal-backdrop`, `--z-toast`, `--z-popover`, `--z-sticky-header` values and layering rules
- `dashboard_widget_config_schema.md` — dashboard-card configuration structure, KPI tile definitions
- `export_pipeline_ui_spec.md` — Toast (success variant, export-completion no-auto-dismiss rule), Modal (form md variant for export dialog)
- `accountant_pack_ui_spec.md` — Modal (step-up-mfa variant for "Send now"), Input (read-only state on mobile)
