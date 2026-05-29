# Error Boundary UI Spec

**Category:** UI · Block 01 — Cross-cutting
**Status:** Authoritative
**Cross-ref:** design_system_tokens.md, severity_color_tokens.md, component_library_variant_catalog.md

---

## 1. Overview

This document defines error boundary types, error state designs, and recovery patterns used across the application. Error boundaries are a first-class concern: every route, data-fetching component, and form must have a defined failure mode. Errors are never silent.

There are three distinct boundary types:

- **Page-level** — wraps an entire route; triggers when the route fails to load
- **Component-level** — wraps individual widgets or cards; failure is scoped and non-blocking
- **Form-level** — wraps form submission and field validation; errors surface inline

---

## 2. Page-Level Error States

Page-level errors replace the full viewport content. The navigation shell (sidebar, top bar) remains visible where technically possible.

### 2.1 404 — Resource Not Found

- **Trigger:** The requested entity does not exist in the current business context, or the URL path is invalid.
- **Heading:** "This page doesn't exist."
- **Body:** "Go back to dashboard."
- **Actions:** Primary button — "Go to Dashboard" (navigates to `/dashboard`).
- **Illustration:** Minimal outlined graphic; no colour fill.
- **HTTP context:** Returned when the API responds with 404 on a resource the route depends on.

### 2.2 403 — Permission Denied

- **Trigger:** The authenticated user's role does not permit access to the requested resource.
- **Heading:** "You don't have access to this resource."
- **Body:** No additional copy. Do not leak what the resource contains.
- **Actions:** Primary button — "Go to Dashboard". Secondary button — "Contact your admin" (opens a mailto: link to the workspace owner's email).
- **Role visibility:** Shown to VIEWER and ACCOUNTANT when they attempt a route restricted to ADMIN/OWNER.

### 2.3 401 — Session Expired

- **Trigger:** The session token has expired or been revoked server-side.
- **Behaviour:** The user is immediately redirected to `/login`. A query parameter `?reason=session_expired` is appended.
- **Login page banner:** "Your session has expired. Please sign in again." Displayed as a yellow info banner at the top of the login form. Auto-dismissed after sign-in succeeds.
- **No intermediate error page:** The redirect is immediate; no full-page error state is shown for 401.

### 2.4 500 / 503 — Server Error

- **Trigger:** The API returns a 5xx response on a route-critical request, or the route fails to render due to an unhandled exception.
- **Heading:** "Something went wrong on our end."
- **Body:** "We're working on it."
- **Actions:**
  - Primary button — "Retry" (re-fetches the route without a full navigation; uses React Query `refetch` or equivalent).
  - Secondary link — "Check status" (opens `status.{product_domain}` in a new tab).
- **Error ID:** Display a short error reference ID if available from the API response (`error.reference_id`). Format: `Ref: ERR-{id}`. Allows support lookup.
- **Auto-retry:** No silent auto-retry on page-level 5xx. The user must click Retry explicitly.

---

## 3. Component-Level Error States

Each data-fetching component (tables, KPI cards, charts, lists) must render a fallback UI when its data request fails, without breaking the surrounding page.

### 3.1 Fallback UI Design

- Container: the component's normal bounding box is preserved; height is maintained to prevent layout shift.
- Background: `--color-surface-muted` (muted grey, from design_system_tokens.md).
- Border: 1px `--color-border-subtle` dashed.
- Content: centred vertically and horizontally.
  - Icon: a circular arrow (refresh) icon, `--color-icon-secondary` colour, 20px.
  - Text: "Failed to load [component name]. Retry?" — `--font-size-sm`, `--color-text-secondary`.
  - The component name is passed as a prop to the error boundary wrapper: `<ErrorBoundary name="Transaction Table">`.
- **Retry behaviour:** Clicking the fallback triggers a re-fetch of the component's data query only. No full page reload. The spinner replaces the fallback while re-fetching.

### 3.2 Implementation Pattern

Every component that fetches data is wrapped in `<ComponentErrorBoundary name="...">`. The boundary catches both React render errors and async query errors (via error state from the query hook). Boundary errors are logged to the application error tracker with the component name, route, and user role.

### 3.3 Nested Boundaries

If a page has multiple independent data-fetching components (e.g., a dashboard with 4 KPI cards and a transactions table), each component has its own boundary. One component failing does not trigger the page-level boundary.

---

## 4. Form-Level Errors

### 4.1 Field Validation Errors

- **Position:** Inline, immediately below the field that failed validation.
- **Style:** Red border (`--color-border-error`) on the input; error message in `--color-text-error`, `--font-size-sm`.
- **Trigger:** On blur (field-level) and on submit (all fields).
- **Example:** "VAT number must be in the format CY12345678X."

### 4.2 Submission Errors (API)

- **Position:** A red error banner displayed above the form submit button, below all fields.
- **Content:** The API error message, or a generic fallback: "Something went wrong. Please try again."
- **Style:** `--color-surface-error-subtle` background; `--color-text-error` text; left border accent 4px `--color-border-error`.

### 4.3 Multi-Field Error Summary

- **Trigger:** More than 3 field-level validation errors exist when the form is submitted.
- **Position:** Top of the form, above the first field.
- **Design:** Red summary box listing each error as a bullet with anchor links that scroll to the relevant field.
- **Heading:** "Please fix the following errors before continuing."
- **Dismissal:** The summary auto-dismisses when all listed errors are resolved.

---

## 5. Toast Notifications

Toasts are non-blocking feedback for actions that complete asynchronously or after a state change.

### 5.1 Position

- **Desktop:** Top-right corner; 16px from the right edge, 16px from the top of the viewport.
- **Mobile:** Bottom of the screen; 16px from the bottom safe area edge.
- **Stacking:** Multiple toasts stack vertically. Maximum 3 visible at once; oldest dismissed when the stack exceeds 3.

### 5.2 Types and Colours

| Type    | Background token              | Icon    | Dismiss behaviour      |
|---------|-------------------------------|---------|------------------------|
| success | `--color-surface-success`     | check   | Auto-dismiss, 5 seconds |
| error   | `--color-surface-error`       | x-circle | Persistent; manual dismiss required |
| warning | `--color-surface-warning`     | alert-triangle | Auto-dismiss, 8 seconds |
| info    | `--color-surface-info`        | info    | Auto-dismiss, 5 seconds |

### 5.3 Content

- **Title:** Bold, max 60 characters.
- **Body:** Optional; one line, max 100 characters.
- **Action link:** Optional; single CTA (e.g., "View invoice") — navigates in-app, does not open a new tab.
- **Close button:** Always present (X icon). Keyboard-accessible.

### 5.4 Persistence Rule for Errors

Error toasts that require action (e.g., "PDF generation failed — Retry") are persistent. They are not auto-dismissed. The user must either click the action or the close button.

---

## 6. Empty States

Empty states are intentional and distinct from error states. An empty state means there is no data yet — not that something went wrong.

### 6.1 Design

- Container: centred within the component or page area.
- Illustration: a simple outlined SVG relevant to the context (invoices, transactions, documents). Illustrations are neutral; no colour fill. Max 120px height.
- Heading: short, contextual — e.g., "No invoices yet."
- Body: one line of context — e.g., "Invoices you create will appear here."
- CTA: a primary button with a creation action — e.g., "Create your first invoice".

### 6.2 Empty vs. Error

Never show an empty state when a fetch is in progress or has failed. Loading state: spinner. Failed state: component error boundary (Section 3). Empty state: only rendered when the query succeeded and returned zero results.

---

## 7. Offline Detection

When `navigator.onLine` becomes `false`, a top-of-viewport sticky banner is displayed.

- **Content:** "You appear to be offline. Some actions may not be available."
- **Style:** `--color-surface-warning` background; full viewport width; 40px height; centred text; `--font-size-sm`.
- **Dismissal:** Not dismissible manually. The banner disappears automatically when `navigator.onLine` returns `true` (the `online` event fires).
- **Write operations:** Form submissions and tool invocations that require network access are disabled while offline. Affected buttons show a tooltip: "Not available offline."
- **Read operations:** Cached data continues to display. Stale data is not flagged during the offline period.

---

## 8. Mobile-Specific Behaviour

| Scenario              | Desktop behaviour                    | Mobile override                           |
|-----------------------|--------------------------------------|-------------------------------------------|
| Toast position        | Top-right                            | Bottom of screen, above safe area         |
| Page-level error      | Full viewport, nav shell visible     | Full-screen; "Go home" button; no sidebar |
| Component error       | Inline fallback in component bounds  | Same; ensure fallback height is sufficient for tap target |
| Form error summary    | Above first field                    | Same; ensure visible above keyboard       |
| Offline banner        | Top sticky                           | Top sticky; same design                  |

---

## 9. Logging and Observability

All boundary catches emit to the application error tracker (Sentry or equivalent):

- Component name (for component boundaries)
- Route path
- User role (not user ID — avoid PII in error logs)
- Error message and stack trace
- Browser / device context

Page-level 500 catches additionally log the API `error.reference_id` if present.
