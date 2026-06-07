import { redirect } from "next/navigation";

import { Alert } from "@/components/ui";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import SignOutOthersButton from "./SignOutOthersButton";

type SessionRow = {
  id: string;
  created_at: string;
  updated_at: string;
  factor_id: string | null;
  aal: string | null;
  user_agent: string | null;
  ip: string | null;
};

export default async function SessionsPage() {
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  let sessions: SessionRow[] = [];
  let error: string | null = null;
  // BOOK-964: the `auth` schema isn't exposed via PostgREST. Read the caller's
  // own sessions through the SECURITY DEFINER RPC (scoped by auth.uid()).
  {
    const { data, error: queryErr } = await supabase.rpc("list_my_sessions");
    if (queryErr) error = queryErr.message;
    else sessions = (data as unknown as SessionRow[]) ?? [];
  }

  return (
    <div className="flex flex-col gap-4">
      <p className="text-sm text-text-secondary">
        Devices signed in to your account. Revoking signs that device out.
      </p>

      {error && <Alert variant="status-danger" title="Couldn’t load sessions">{error}</Alert>}

      <section className="rounded-xl border border-border-subtle bg-surface-default p-5 shadow-1">
        <ul className="divide-y divide-border-subtle">
          {sessions.length === 0 && !error && (
            <li className="py-3 text-sm text-text-muted">No active sessions.</li>
          )}
          {sessions.map((s) => (
            <li key={s.id} className="space-y-1 py-3 text-sm">
              <p className="font-medium text-text-primary">{s.user_agent ?? "Unknown device"}</p>
              <p className="text-xs text-text-muted tabular-nums">
                {s.ip ? `IP ${s.ip} · ` : ""}AAL {s.aal ?? "?"} · last active{" "}
                {new Date(s.updated_at).toLocaleString("en-GB")}
              </p>
            </li>
          ))}
        </ul>
      </section>

      <SignOutOthersButton />

      <p className="text-xs text-text-muted">
        Per-session revoke is intentionally deferred — the spec’s “Revoke a specific session”
        deliverable needs the Supabase Auth admin signOut(sessionId) primitive, which lands when
        B05’s audit log receives the revocation event so the trail stays complete. Until then,
        “Sign out everywhere else” covers the security-critical case.
      </p>
    </div>
  );
}
