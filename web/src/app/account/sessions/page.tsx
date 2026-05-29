import Link from "next/link";
import { redirect } from "next/navigation";

import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import SignOutOthersButton from "./SignOutOthersButton";

type SessionRow = {
  id: string;
  user_id: string;
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
  try {
    const admin = createSupabaseAdminClient();
    const { data, error: queryErr } = await admin
      .schema("auth")
      .from("sessions")
      .select("id, user_id, created_at, updated_at, factor_id, aal, user_agent, ip")
      .eq("user_id", user.id)
      .order("updated_at", { ascending: false });
    if (queryErr) error = queryErr.message;
    else sessions = (data as unknown as SessionRow[]) ?? [];
  } catch (err) {
    error =
      err instanceof Error
        ? err.message
        : "Service-role key not configured; sessions are read via the admin client.";
  }

  return (
    <div className="space-y-5">
      <div>
        <Link
          href="/account"
          className="text-sm text-zinc-500 hover:underline dark:text-zinc-400"
        >
          ← Account
        </Link>
        <h1 className="mt-2 text-xl font-medium text-zinc-900 dark:text-zinc-50">
          Sessions
        </h1>
        <p className="mt-1 text-sm text-zinc-500">
          Devices signed in to your account. Revoking signs that device out.
        </p>
      </div>

      {error && (
        <div className="rounded-md border border-red-300 bg-red-50 p-3 text-sm text-red-800 dark:border-red-700 dark:bg-red-950 dark:text-red-200">
          Could not load sessions: {error}
        </div>
      )}

      <section className="rounded-lg border border-zinc-200 bg-white p-5 dark:border-zinc-800 dark:bg-zinc-900">
        <ul className="divide-y divide-zinc-200 dark:divide-zinc-800">
          {sessions.length === 0 && !error && (
            <li className="py-3 text-sm text-zinc-500">No active sessions.</li>
          )}
          {sessions.map((s) => (
            <li key={s.id} className="space-y-1 py-3 text-sm">
              <p className="font-medium text-zinc-900 dark:text-zinc-50">
                {s.user_agent ?? "Unknown device"}
              </p>
              <p className="text-xs text-zinc-500">
                {s.ip ? `IP ${s.ip} · ` : ""}AAL {s.aal ?? "?"} · last active{" "}
                {new Date(s.updated_at).toLocaleString()}
              </p>
            </li>
          ))}
        </ul>
      </section>

      <SignOutOthersButton />

      <p className="text-xs text-zinc-500">
        Per-session revoke is intentionally deferred — the spec's "Revoke
        a specific session" deliverable needs the Supabase Auth admin
        signOut(sessionId) primitive, which lands when B05's audit log
        receives the revocation event so the audit trail stays complete.
        Until then, "Sign out everywhere else" covers the security-critical
        case (a stolen-device evict).
      </p>
    </div>
  );
}
