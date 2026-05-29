import { redirect } from "next/navigation";

import { createSupabaseServerClient } from "@/lib/supabase/server";
import InviteForm from "./InviteForm";
import RevokeInvitationButton from "./RevokeInvitationButton";

type MemberRow = {
  user_id: string;
  email: string;
  display_name: string | null;
  business_id: string;
  business_name: string;
  role: string;
  role_status: string;
  joined_at: string;
};

type PendingInvitation = {
  id: string;
  email: string;
  invited_role_per_business: Array<{ business_id: string; role: string }>;
  expires_at: string;
  created_at: string;
};

type BusinessOption = { id: string; display_name: string; organization_id: string };

export default async function TeamPage() {
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  // Resolve the active organization via the public.users → organization_users join.
  const { data: profileRow } = await supabase
    .from("users")
    .select("id")
    .eq("auth_user_id", user.id)
    .single();
  if (!profileRow) {
    return (
      <div className="mx-auto max-w-3xl p-6">
        <h1 className="text-xl font-medium">Team</h1>
        <p className="mt-3 text-sm text-zinc-600">
          No profile row yet. Sign in once after sign-up so the user row syncs.
        </p>
      </div>
    );
  }

  const { data: orgMembership } = await supabase
    .from("organization_users")
    .select("organization_id")
    .eq("user_id", profileRow.id)
    .eq("status", "ACTIVE")
    .order("joined_at", { ascending: true })
    .limit(1)
    .maybeSingle();

  if (!orgMembership) {
    return (
      <div className="mx-auto max-w-3xl p-6">
        <h1 className="text-xl font-medium">Team</h1>
        <p className="mt-3 text-sm text-zinc-600">
          You are not a member of any organization yet.
        </p>
      </div>
    );
  }

  const organizationId = orgMembership.organization_id;

  const [{ data: membersData, error: membersErr }, { data: businessesData }, { data: invitationsData }] =
    await Promise.all([
      supabase.rpc("list_organization_members", { p_organization_id: organizationId }),
      supabase
        .from("business_entities")
        .select("id, display_name, organization_id")
        .eq("organization_id", organizationId)
        .order("display_name", { ascending: true }),
      supabase
        .from("organization_invitations")
        .select("id, email, invited_role_per_business, expires_at, created_at")
        .eq("organization_id", organizationId)
        .eq("status", "PENDING")
        .order("created_at", { ascending: false }),
    ]);

  const members: MemberRow[] = (membersData as MemberRow[] | null) ?? [];
  const businesses: BusinessOption[] = (businessesData as BusinessOption[] | null) ?? [];
  const invitations: PendingInvitation[] = (invitationsData as PendingInvitation[] | null) ?? [];

  if (membersErr && !membersErr.message.includes("MEMBERS_REQUIRES_OWNER_OR_ADMIN")) {
    return (
      <div className="mx-auto max-w-3xl p-6">
        <h1 className="text-xl font-medium">Team</h1>
        <p className="mt-3 text-sm text-red-700">Could not load members: {membersErr.message}</p>
      </div>
    );
  }

  const isOwnerOrAdmin = !membersErr;

  // Group rows per user → [businesses]
  const byUser = new Map<string, { email: string; name: string | null; rows: MemberRow[] }>();
  for (const r of members) {
    if (!byUser.has(r.user_id)) {
      byUser.set(r.user_id, { email: r.email, name: r.display_name, rows: [] });
    }
    byUser.get(r.user_id)!.rows.push(r);
  }

  return (
    <div className="mx-auto max-w-4xl space-y-8 p-6">
      <header>
        <h1 className="text-xl font-medium text-zinc-900 dark:text-zinc-50">Team</h1>
        <p className="mt-1 text-sm text-zinc-500">
          Members and pending invitations in your organization.
        </p>
      </header>

      {isOwnerOrAdmin && businesses.length > 0 && (
        <section className="rounded-lg border border-zinc-200 p-4 dark:border-zinc-800">
          <h2 className="text-base font-medium">Invite a new member</h2>
          <InviteForm organizationId={organizationId} businesses={businesses} />
        </section>
      )}

      <section className="rounded-lg border border-zinc-200 dark:border-zinc-800">
        <header className="border-b border-zinc-200 p-4 dark:border-zinc-800">
          <h2 className="text-base font-medium">Members</h2>
        </header>
        <ul className="divide-y divide-zinc-200 dark:divide-zinc-800">
          {byUser.size === 0 && (
            <li className="p-4 text-sm text-zinc-500">No members yet.</li>
          )}
          {Array.from(byUser.entries()).map(([uid, info]) => (
            <li key={uid} className="space-y-2 p-4">
              <div>
                <p className="text-sm font-medium text-zinc-900 dark:text-zinc-50">
                  {info.name ?? info.email}
                </p>
                <p className="text-xs text-zinc-500">{info.email}</p>
              </div>
              <ul className="space-y-1 text-sm">
                {info.rows.map((r) => (
                  <li key={`${r.user_id}:${r.business_id}`} className="text-zinc-700 dark:text-zinc-300">
                    <span className="font-mono text-xs text-zinc-500">{r.role}</span>{" "}
                    on <span className="font-medium">{r.business_name}</span>
                    {r.role_status !== "ACTIVE" && (
                      <span className="ml-1 text-xs text-zinc-500">({r.role_status})</span>
                    )}
                  </li>
                ))}
              </ul>
            </li>
          ))}
        </ul>
      </section>

      {isOwnerOrAdmin && (
        <section className="rounded-lg border border-zinc-200 dark:border-zinc-800">
          <header className="border-b border-zinc-200 p-4 dark:border-zinc-800">
            <h2 className="text-base font-medium">Pending invitations</h2>
          </header>
          <ul className="divide-y divide-zinc-200 dark:divide-zinc-800">
            {invitations.length === 0 && (
              <li className="p-4 text-sm text-zinc-500">No pending invitations.</li>
            )}
            {invitations.map((inv) => (
              <li key={inv.id} className="flex items-center justify-between gap-4 p-4 text-sm">
                <div>
                  <p className="font-medium text-zinc-900 dark:text-zinc-50">{inv.email}</p>
                  <p className="text-xs text-zinc-500">
                    Sent {new Date(inv.created_at).toLocaleString()} · expires{" "}
                    {new Date(inv.expires_at).toLocaleString()}
                  </p>
                  <p className="mt-1 text-xs text-zinc-500">
                    {inv.invited_role_per_business
                      .map(
                        (a) =>
                          `${a.role} on ${businesses.find((b) => b.id === a.business_id)?.display_name ?? a.business_id}`,
                      )
                      .join(" · ")}
                  </p>
                </div>
                <RevokeInvitationButton invitationId={inv.id} />
              </li>
            ))}
          </ul>
        </section>
      )}
    </div>
  );
}
