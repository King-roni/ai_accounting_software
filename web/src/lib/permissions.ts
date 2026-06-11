/**
 * BOOK-972 — client-side action gates for UI affordances.
 *
 * These mirror `permission_matrix` for the relevant surfaces so a role doesn't
 * see action buttons it can't use (which would error on click). The server
 * (`can_perform` + RLS) remains the authoritative enforcement — this only hides
 * affordances; it never grants access.
 *
 * Surfaces (per permission_matrix):
 *   - workflow_run  → OWNER, ADMIN            (upload statement, start/trigger a run)
 *   - CLIENT_MANAGE → OWNER, ADMIN, BOOKKEEPER (create/manage clients)
 */
export type BusinessRole =
  | "OWNER" | "ADMIN" | "BOOKKEEPER" | "ACCOUNTANT" | "REVIEWER" | "READ_ONLY";

const WORKFLOW_RUN_ROLES = new Set<string>(["OWNER", "ADMIN"]);
const CLIENT_MANAGE_ROLES = new Set<string>(["OWNER", "ADMIN", "BOOKKEEPER"]);

export const can = {
  uploadStatement: (role?: string | null) => !!role && WORKFLOW_RUN_ROLES.has(role),
  startPeriod: (role?: string | null) => !!role && WORKFLOW_RUN_ROLES.has(role),
  manageClients: (role?: string | null) => !!role && CLIENT_MANAGE_ROLES.has(role),
};
