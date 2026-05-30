# Design Brief — Cyprus Bookkeeping SaaS (for a UI/UX mockup session)

**Purpose of this document.** You (the design session) will produce a visual UI/UX
mockup for this product. This brief gives you **everything the real backend already
provides** — the exact screens, data, entities, statuses, and constraints — so your
mockup is *implementable as-is* and doesn't invent data the system can't supply.

**The golden rule:** every screen is backed by a real database + RPC layer that is
**already built**. Design against the data described here. Do **not** invent new
fields, statuses, or entities; if a screen needs something not listed, flag it
explicitly as "NEW — needs backend" rather than assuming it exists.

**What we want back:** a cohesive visual system (color, type, spacing, elevation,
component styling) + per-screen layouts for the priority screens listed at the end.
Output as annotated mockups and, ideally, a described **design-token palette** (we
implement with CSS variables, so concrete hex values + a component-styling direction
translate directly).

---

## 1. The product in one paragraph

A bookkeeping-automation SaaS for **Cyprus** SMEs and their accountants. It ingests a
business's **bank statement**, classifies each transaction, finds supporting
**evidence** (invoices/receipts via email/drive), **matches** transactions to
documents, drafts **ledger entries** with correct **Cyprus VAT** treatment, routes
exceptions to a **review queue**, then **finalizes** the month behind approval +
step-up auth and writes a tamper-evident **archive**. It runs two paired monthly
workflows: **OUT** (expenses/payables) and **IN** (income/receivables, incl. issuing
**invoices**). Everything is **multi-business** and **period (month) scoped**.

**Who uses it:** SME owners and bookkeepers/accountants. **Tone:** trustworthy,
calm, accountant-grade, precise — premium but not flashy. Numbers must read
cleanly (tabular figures). It should feel like financial software you can trust,
not a consumer app.

**Two ever-present global controls** (top nav): the **Business switcher** (a user
may have several businesses; there's also an "All businesses" overview mode) and the
**Period switcher** (the accounting month). Changing either re-scopes every screen.
Your design must keep both prominent and obvious.

---

## 2. Global shell & navigation (already built — restyle, don't re-architect)

**Top bar (left→right):** product logo · **Business switcher** (avatar + name) ·
**Period switcher** (‹ "May 2026" ›) · spacer · **Search / ⌘K command palette** ·
**Notifications** bell · **Language** (EN / Ελληνικά) · **Theme** (light/system/dark) ·
**User menu** (avatar).

**Left sidebar (collapsible), 3 sections:**
- *Primary:* Dashboard
- *Domain:* Transactions, Invoices, Documents, Matching, Ledger, Reviews, Periods, Reports, Subscriptions, Team, Clients
- *Account:* Settings, Help

**Mobile:** bottom nav (Dashboard, Reviews, Periods, Reports, More) + the app is
**read-only on phones** (create/edit hidden, a small "viewing only on mobile" banner
shows). Design a mobile read state, not full mobile CRUD.

**Light + dark themes** are both first-class. **EN + Greek (el)** localization exists.
Accessibility target is **WCAG 2.1 AA** (4.5:1 contrast; color is never the only
signal — always icon + text).

---

## 3. The screens (with their REAL data)

For each: route, purpose, the real entities/fields, the states, and the actions.
Treat field names as the source of truth for what can be shown.

### 3.1 Dashboard — `/dashboard`
A grid of **11 cards** (each has a `data_source`: Live / Analytics / Archive, and a
`chart_type`). Cards by `default_position`:
1. **Monthly Overview** (KPI) · 2. **Income Overview** (bar) · 3. **Expense Overview**
(bar) · 4. **VAT Summary** (donut) · 5. **Recurring Revenue** (line) · 6. **Client
Invoice Aging** (table) · 7. **Unresolved Review Items** (list) · 8. **Evidence
Collection Status** (KPI) · 9. **Recent Finalizations** (list) · 10. **Tax Treatment
Breakdown** (donut) · 11. **Unmatched Transactions** (list).
- Each card shows a headline + small viz + preview rows; clicking opens a **drill-down**
  panel (list of underlying records).
- ⚠️ The **analytics** cards (Monthly/Income/Expense/VAT/Tax/Recurring) currently return
  a *backend stub* — the aggregation layer isn't built yet. Design their "rich chart"
  state, but know real data only exists for the operational/list cards today.
- A "Refresh" affordance exists. Multi-business mode aggregates across businesses.

### 3.2 Transactions — `/transactions`
Bank-statement lines for the period. Fields per row: `transaction_date`, `amount`
(**signed**: IN positive / OUT negative), `currency`, `direction` (IN/OUT/BOTH),
`transaction_type` (one of: OUT_EXPENSE, IN_INCOME, INTERNAL_TRANSFER, FX_EXCHANGE,
BANK_FEE, REFUND_IN, REFUND_OUT, CHARGEBACK, LOAN_OR_SHAREHOLDER_MOVEMENT,
PAYROLL_OR_TEAM_PAYMENT, TAX_PAYMENT, UNKNOWN), `counterparty_name`, description,
`reference`, and four status fields: `classification_status`
(PENDING/NEEDS_CONFIRMATION/CONFIRMED/FAILED), `dedup_status`
(NEW/DUPLICATE_EXACT/DUPLICATE_PROBABLE/NEEDS_REVIEW), `match_status`, `review_status`,
plus system/user tags. List + stat tiles (totals in/out) + filters + a **detail
drawer** + a statement **upload** entry point.

### 3.3 Invoices — `/invoices` (two tabs: **Invoices** + **Recurring**)
**Invoices tab:** list filtered by lifecycle. An invoice has: `invoice_number`
(or "Draft"), `invoice_type` (PRO_FORMA / TAX), client, `issue_date`, `supply_date`,
`due_date`, `currency`, `subtotal_amount`, `vat_amount`, `total_amount`, and
`lifecycle_status` — one of **12**: DRAFT, SENT, PAYMENT_EXPECTED, PARTIALLY_PAID,
PAID, OVERPAID, REFUNDED, WRITTEN_OFF, CREDITED, CONVERTED_TO_TAX_INVOICE, FINALIZED,
EXPIRED_UNCONVERTED. **Lines:** description, quantity, unit_price, vat_treatment,
vat_rate_pct, vat_amount, total. **Create** flow = pick client → type → dates →
currency → line editor (VAT per-line or one default treatment) → totals computed
server-side. **Detail drawer** actions (shown by status): allocate number, mark sent,
convert pro-forma→tax, write off, **issue credit note**, **preview PDF data**.
**Recurring tab:** templates with `template_name`, client, `cadence` (WEEKLY,
BIWEEKLY, MONTHLY, QUARTERLY, SEMI_ANNUAL, ANNUAL), anchor day, `next_due_date`,
`auto_send`, status (ACTIVE/PAUSED/ENDED) + pause/resume/end.

### 3.4 Documents — `/documents`
Document intake (uploaded/discovered invoices & receipts) + an **extraction review**
showing per-field extracted values with **confidence** indicators. Image/PDF render
pane is deferred (no file render yet). Upload entry point.

### 3.5 Matching — `/matching`
Card-based review of proposed **transaction ↔ document** matches. Each match shows
**signal bars** (how strong the match is) and **plain-language reasons** ("Amount and
date match this AWS invoice"). Actions: **Confirm** / **Reject**. Accountant-friendly,
not jargon.

### 3.6 Ledger — `/ledger`
Draft/locked ledger entries + a **Cyprus VAT summary** (input VAT, output VAT, net),
reverse-charge & VIES flags, accountant-review status, chart-of-accounts names. KPI
tiles use green for income/"in", red for expense/"out". Detail drawer per entry.

### 3.7 Reviews — `/reviews`
The exception **review queue**. Issues grouped into **5 buckets**, each issue has a
**severity** (LOW / MEDIUM / HIGH / BLOCKING), a **plain-language title + description**
(written for a non-accountant), and a **recommended action** that routes to the right
screen. Cards sorted by severity. Actions: **Assign to me**, **Snooze**, resolve
(routes to matching/ledger/etc.). Some actions can be **denied** (e.g. you can't
snooze a BLOCKING issue) — the backend returns a reason; design a clear "can't do
that, here's why" inline state.

### 3.8 Periods — `/periods` (two tabs: **Periods** + **Archive**)
The monthly workflow cockpit. Each period shows a card with the **paired OUT + IN runs**.
- **Workflow run** has `workflow_type` (OUT_MONTHLY / IN_MONTHLY / OUT_ADJUSTMENT /
  IN_ADJUSTMENT), `status` — one of **11**: CREATED, RUNNING, PAUSED, REVIEW_HOLD,
  AWAITING_APPROVAL, FINALIZING, FINALIZED, FAILED, CANCELLED, COMPENSATING, ABORTED —
  and a `period_start/end`.
- **Run detail** (drawer) shows the **phase plan** as an ordered checklist. OUT has
  **11 phases**: Ingestion, Classification, Out-filter, Evidence discovery (email)*,
  Evidence discovery (drive)*, Matching, Manual-upload hold*, Ledger preparation,
  AI end-scan, Human-review hold*, Finalization (* = optional/side phase). IN has 8.
  Each phase has a status: PENDING / RUNNING / COMPLETED / FAILED / SKIPPED / HOLDING,
  and may carry a gate decision (Advance / Hold / Side-phase).
- A **Finalization readiness checklist**: 9 gates (transactions processed, no unknown
  types, VAT complete, ledger entries complete, evidence satisfied, no blocking issues,
  audit quiescent, approval recorded, step-up approval present) each pass/fail with a
  reason; plus a **step-up "Approve & finalize"** action.
- **"Start a period"** creates the paired OUT+IN runs for a chosen month.
- **Approvals** list; contextual actions (approve, clear hold, send reminder).
- **Archive tab:** finalized periods as locked, tamper-evident **archive packages**
  (period, original vs adjustment, step-up used, hash anchor, date) + **Verify integrity**.

### 3.9 Reports — `/reports` (two tabs: **Available reports** + **Export history**)
**Catalogue** of **13 export kinds** (each with formats + scope): Transaction report
(CSV/XLSX), Income/Expense report (CSV/XLSX/PDF), Invoice match report (CSV), Missing
evidence report (PDF/CSV), Supplier overview (CSV), Client outstanding report (PDF),
Finalized archive package (ZIP), Accountant export pack (ZIP), Cashflow overview (PDF),
Profit/loss overview (PDF), **VAT preparation report** (PDF/JSON), **VIES file**
(XML, regulator format). "Generate" → choose format + period → queue. **History** list
with status (Queued / Generating / Ready / Failed) + Download (active only when ready).
⚠️ File generation runs in a worker that's not wired yet — exports sit "Queued" today.

### 3.10 Clients — `/clients`
Client list + search. Fields: `display_name`, `legal_name`, `country` (ISO + flag),
`vat_number` (+ a format-valid badge), default currency, default payment terms,
default VAT treatment, billing address/email, active/inactive. Create/edit drawer;
disable.

### 3.11 Others
**Subscriptions** `/subscriptions` (future: recurring *vendor spend* / MRR-style
view — placeholder today), **Team** `/team`, **Settings** `/account` (auth, integrations,
VAT settings), **Help** `/help`, plus auth screens (`/login`, signup, MFA, forgot/reset).

---

## 4. Domain reference — exact labels & semantics

**Cyprus VAT treatments** (used on invoices/lines/clients): Domestic standard (19%),
Domestic reduced (9% / 5%), Domestic zero-rated, EU reverse charge, Import/acquisition,
Non-EU service, Outside scope, Exempt, No VAT. (VAT is central — design space for VAT
breakdowns, reverse-charge and VIES flags.)

**Severity scale** (review queue): LOW · MEDIUM · HIGH · BLOCKING. Use a distinct
quartet of colors **with icons** (color is never the only cue). A separate analytics
severity scale exists (CRITICAL/HIGH/MEDIUM/LOW) for system health.

**Status families that need badges:** invoice lifecycle (12), run status (11), phase
status (6), transaction classification/dedup/match/review, export status (4), client
active/inactive, template ACTIVE/PAUSED/ENDED. Design a **coherent badge system** that
covers severity (4), status-success/info/neutral/warning/danger, and these domain
states without becoming a rainbow.

**Money:** every amount has a `currency`; amounts are **signed** (IN positive, OUT
negative); render with **tabular/monospaced figures**. Income = green, expense = red,
but both must pass AA contrast (we use darker shades for colored *text*).

---

## 5. Existing design system (what you're restyling)

It's **token-driven** (CSS variables) — so if you give concrete values, a big visual
change is mostly re-skinning, not a rebuild. Current tokens/inventory:

- **Color tokens:** neutral / brand (blue) / success (green) / warning (amber) /
  danger (red) / info scales (50→900). Semantic: `text-primary/secondary/muted`,
  `bg-base/raised/overlay/canvas`, `surface-default`, `border-subtle/default/strong/focus`,
  `action-primary/hover/active`, `status-success/info/warning/danger` (+ darker `-text`
  variants for colored text), and a **severity quartet** (blocking/high/medium/low,
  each with bg/border/text/icon). Light + dark sets.
- **Type:** Inter (UI), JetBrains Mono (numbers/code). Define a type scale.
- **Elevation:** shadow tokens (elev 1–3); **radius** + **spacing** scales; z-index tokens.
- **Components (already exist):** Button (primary/secondary/tertiary/danger/ghost ×
  sm/md/lg), Badge (severity + status families), Alert, Card (+ left-accent), Skeleton,
  Empty/Error states, Input, Textarea, Select, Tabs (underlined/pill), Modal, Drawer
  (right slide-in), Table (sortable, density, row-selection), Toast, Popover/Menu.
  Charts: lightweight SVG Bar/Donut/Sparkline.

Design **around these primitives**. If you introduce a new component or pattern, name
it so we can add it.

---

## 6. Hard constraints the mockup MUST respect

1. **Multi-business + period scoping is global.** Keep the business switcher + period
   switcher prominent; most screens are "for this business, this month."
2. **Actions can be denied with a reason** (permission/state gates). Every primary
   action needs an inline "allowed vs. denied-with-reason" state, not just success/error.
3. **What's real vs. stubbed today** (design the full state, but know data is thin now):
   - ✅ Real: clients, invoices (+lifecycle, credit notes, recurring), workflow runs
     (phases/gates/approvals/finalization readiness), archive packages, review queue,
     transactions/ledger, the dashboard *operational/list* cards, the export catalogue.
   - ⏳ Stubbed/pending backend (R4): dashboard **analytics charts** (aggregation MVs),
     **export file generation + download**, **document image/PDF render**, **statement
     parse→results viewer**, real AI/OCR. Design these as first-class; they'll light up
     when the backend lands.
4. **Accountant-grade tone:** plain-language explanations (esp. review queue + matching),
   trustworthy, calm. Avoid gamification, avoid hiding numbers.
5. **AA accessibility:** 4.5:1 contrast; never color-only; visible focus; works in light
   AND dark.
6. **It's a real app, not a marketing page** — design the working product surfaces
   (data-dense tables, drawers, multi-step flows), not a landing page.

---

## 7. What we'd love from this session (priority order)

Mock these first — they define the visual language and are the most-used:
1. **Dashboard** (the card grid — this is "the dashboard" the owner pictures).
2. **Periods / run detail** (the workflow cockpit + finalization readiness — the
   product's signature flow).
3. **Transactions** (the data-dense table archetype).
4. **Invoices** (list + create + detail drawer — the richest CRUD).
5. **Reviews** (the severity-driven queue).
6. **Ledger / VAT** (the financial-summary archetype).

For each: desktop layout (and a note on the light/dark treatment). Plus a **global
visual system**: color palette (concrete values), type scale, spacing/radius/elevation,
and how the badge/status system looks. A **dark-first** or **light-first** call is
welcome — both must work.

Deliverable format that's easiest for us to implement: annotated mockup images **plus**
a short token spec (palette hexes + font choices + radius/shadow direction). We map
that to CSS variables and restyle the existing components.

---

## 8. Things NOT to do
- Don't invent new entities, fields, statuses, or screens not in §3–§4 (or label them
  "NEW — needs backend").
- Don't design flows that bypass the business/period scoping or the approval/step-up
  gates.
- Don't rely on data that's stubbed (§6.3) as if it's rich today — design the target
  state but don't make it load-bearing for the demo.
- Don't make color the only signal for status/severity.
- Don't turn it into a flashy consumer app; it's trustworthy financial software.
