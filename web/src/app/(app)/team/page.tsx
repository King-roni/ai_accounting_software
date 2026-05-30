import { redirect } from "next/navigation";
import { ShieldCheck } from "lucide-react";
import { Badge, type BadgeVariant } from "@/components/ui";
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

const ROLE_BADGE: Record<string, BadgeVariant> = {
  OWNER: "status-info", ADMIN: "status-info", ACCOUNTANT: "status-success",
  BOOKKEEPER: "status-neutral", REVIEWER: "severity-medium", READ_ONLY: "status-neutral",
};
const ROLE_LEGEND: [string, string][] = [
  ["Owner / Admin", "full access + finalize"],
  ["Accountant", "prepare, review, report"],
  ["Bookkeeper", "classify & match"],
  ["Viewer", "read-only"],
];

function Notice({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-5">
      <header><h1 className="text-2xl font-semibold text-text-primary">Team</h1></header>
      <p className="rounded-xl border border-border-subtle bg-surface-default p-5 text-sm text-text-secondary shadow-1">{children}</p>
    </div>
  );
}

export default async function TeamPage() {
  const supabase = await createSupabaseServerClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: profileRow } = await supabase.from("users").select("id").eq("auth_user_id", user.id).single();
  if (!profileRow) return <Notice>No profile row yet. Sign in once after sign-up so the user row syncs.</Notice>;

  const { data: orgMembership } = await supabase
    .from("organization_users").select("organization_id").eq("user_id", profileRow.id).eq("status", "ACTIVE")
    .order("joined_at", { ascending: true }).limit(1).maybeSingle();
  if (!orgMembership) return <Notice>You are not a member of any organization yet.</Notice>;

  const organizationId = orgMembership.organization_id;
  const [{ data: membersData, error: membersErr }, { data: businessesData }, { data: invitationsData }] = await Promise.all([
    supabase.rpc("list_organization_members", { p_organization_id: organizationId }),
    supabase.from("business_entities").select("id, display_name, organization_id").eq("organization_id", organizationId).order("display_name"),
    supabase.from("organization_invitations").select("id, email, invited_role_per_business, expires_at, created_at").eq("organization_id", organizationId).eq("status", "PENDING").order("created_at", { ascending: false }),
  ]);

  const members: MemberRow[] = (membersData as MemberRow[] | null) ?? [];
  const businesses: BusinessOption[] = (businessesData as BusinessOption[] | null) ?? [];
  const invitations: PendingInvitation[] = (invitationsData as PendingInvitation[] | null) ?? [];
  if (membersErr && !membersErr.message.includes("MEMBERS_REQUIRES_OWNER_OR_ADMIN")) {
    return <Notice><span style={{ color: "var(--color-status-danger)" }}>Could not load members: {membersErr.message}</span></Notice>;
  }
  const isOwnerOrAdmin = !membersErr;

  const byUser = new Map<string, { email: string; name: string | null; rows: MemberRow[] }>();
  for (const r of members) {
    if (!byUser.has(r.user_id)) byUser.set(r.user_id, { email: r.email, name: r.display_name, rows: [] });
    byUser.get(r.user_id)!.rows.push(r);
  }
  const memberList = Array.from(byUser.entries());
  const orgName = businesses[0]?.display_name;

  return (
    <div className="flex flex-col gap-5">
      <header>
        <h1 className="text-2xl font-semibold text-text-primary">Team</h1>
        <p className="text-sm text-text-secondary">
          {orgName ? `${orgName} · ` : ""}{memberList.length} member{memberList.length === 1 ? "" : "s"}
          {invitations.length > 0 && ` · ${invitations.length} invited`}
        </p>
      </header>

      {isOwnerOrAdmin && businesses.length > 0 && (
        <div className="rounded-xl border border-border-subtle bg-surface-default p-5 shadow-1">
          <h2 className="text-sm font-semibold text-text-primary">Invite a member</h2>
          <InviteForm organizationId={organizationId} businesses={businesses} />
        </div>
      )}

      <div className="overflow-hidden rounded-xl border border-border-subtle bg-surface-default shadow-1">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b border-border-default bg-bg-raised text-left">
              <th className="px-4 py-2.5 text-[11px] font-semibold uppercase tracking-[0.05em] text-text-muted">Member</th>
              <th className="px-4 py-2.5 text-[11px] font-semibold uppercase tracking-[0.05em] text-text-muted">Role</th>
              <th className="px-4 py-2.5 text-[11px] font-semibold uppercase tracking-[0.05em] text-text-muted">Access</th>
              <th className="px-4 py-2.5 text-[11px] font-semibold uppercase tracking-[0.05em] text-text-muted">Joined</th>
            </tr>
          </thead>
          <tbody>
            {memberList.length === 0 ? (
              <tr><td colSpan={4} className="px-4 py-8 text-center text-text-muted">No members yet.</td></tr>
            ) : memberList.map(([uid, info]) => {
              const roles = [...new Set(info.rows.map((r) => r.role))];
              const joined = info.rows.map((r) => r.joined_at).sort()[0];
              return (
                <tr key={uid} className="border-b border-border-subtle last:border-0">
                  <td className="px-4 py-3">
                    <div className="flex items-center gap-2.5">
                      <span className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full bg-accent-bronze text-xs font-bold text-white">{(info.name ?? info.email)[0]?.toUpperCase()}</span>
                      <div className="min-w-0"><p className="truncate font-medium text-text-primary">{info.name ?? info.email}</p><p className="truncate text-xs text-text-muted">{info.email}</p></div>
                    </div>
                  </td>
                  <td className="px-4 py-3"><span className="flex flex-wrap gap-1">{roles.map((r) => <Badge key={r} variant={ROLE_BADGE[r] ?? "status-neutral"} size="sm">{r.replaceAll("_", " ")}</Badge>)}</span></td>
                  <td className="px-4 py-3 text-text-secondary">{info.rows.map((r) => r.business_name).join(", ")}</td>
                  <td className="px-4 py-3 font-mono text-xs tabular-nums text-text-muted">{joined ? new Date(joined).toLocaleDateString("en-GB") : "—"}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      <div className="flex items-start gap-2.5 rounded-xl border border-border-subtle bg-bg-raised p-4 text-sm text-text-secondary">
        <ShieldCheck size={16} className="mt-0.5 shrink-0 text-action-primary" aria-hidden="true" />
        <p><strong className="text-text-primary">Roles control what each member can do.</strong> Only Owners/Admins can finalize periods and provide step-up authentication. Accountants can prepare and review; Bookkeepers can classify and match; Viewers have read-only access.</p>
      </div>
      <div className="flex flex-wrap gap-x-5 gap-y-1.5 text-xs text-text-muted">
        {ROLE_LEGEND.map(([role, desc]) => <span key={role}><strong className="text-text-secondary">{role}</strong> — {desc}</span>)}
      </div>

      {isOwnerOrAdmin && invitations.length > 0 && (
        <div className="rounded-xl border border-border-subtle bg-surface-default p-5 shadow-1">
          <h2 className="mb-3 text-sm font-semibold text-text-primary">Pending invitations</h2>
          <ul className="flex flex-col gap-2">
            {invitations.map((inv) => (
              <li key={inv.id} className="flex items-center justify-between gap-4 border-t border-border-subtle pt-2 text-sm first:border-0 first:pt-0">
                <div>
                  <p className="font-medium text-text-primary">{inv.email}</p>
                  <p className="text-xs text-text-muted">{inv.invited_role_per_business.map((a) => `${a.role} on ${businesses.find((b) => b.id === a.business_id)?.display_name ?? a.business_id}`).join(" · ")} · expires {new Date(inv.expires_at).toLocaleDateString("en-GB")}</p>
                </div>
                <RevokeInvitationButton invitationId={inv.id} />
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}
