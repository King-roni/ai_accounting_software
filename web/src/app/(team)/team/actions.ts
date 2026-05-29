"use server";

/**
 * Team / invitation server actions (B02·P07).
 *
 *   inviteMember         — Owner/Admin only. Generates a fresh token,
 *                          records the SHA-256 hash via create_invitation,
 *                          dispatches the invite email via Supabase admin
 *                          API with redirectTo /accept-invitation?token=...
 *   acceptInvitation     — hashes the URL token, calls accept_invitation RPC.
 *   revokeInvitation     — Owner/Admin only; calls revoke_invitation RPC.
 *   changeMemberRole     — Owner/Admin + step-up token; calls change_member_role.
 *   removeMember         — Owner/Admin + step-up token; calls remove_member.
 *
 * Audit emission goes to console for now; B05·P02 will register the real emitter.
 */

import { revalidatePath } from "next/cache";

import { appOrigin } from "@/lib/app-origin";
import {
  generateInvitationToken,
  hashInvitationToken,
} from "@/lib/invitation-token";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";
import { createSupabaseServerClient } from "@/lib/supabase/server";

type InviteAssignment = { business_id: string; role: string };

type ErrorResult = { ok: false; error: string; detail?: string };
type OkResult = { ok: true };

function audit(event: string, payload: Record<string, unknown>) {
  console.info(`[audit] ${event}`, payload);
}

export async function inviteMember(input: {
  organizationId: string;
  email: string;
  assignments: InviteAssignment[];
}): Promise<({ ok: true; invitationId: string }) | ErrorResult> {
  const { organizationId, email, assignments } = input;
  if (!organizationId || !email || !assignments?.length) {
    return { ok: false, error: "VALIDATION", detail: "missing required fields" };
  }

  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "NOT_AUTHENTICATED" };

  const { plain, hash } = generateInvitationToken();

  const { data: invitationId, error: rpcErr } = await supabase.rpc(
    "create_invitation",
    {
      p_organization_id: organizationId,
      p_email: email.trim().toLowerCase(),
      p_assignments: assignments,
      p_token_hash: hash,
    },
  );
  if (rpcErr || !invitationId) {
    audit("USER_INVITED_FAILED", {
      organization_id: organizationId,
      email,
      reason: rpcErr?.message,
    });
    return {
      ok: false,
      error: rpcErr?.message?.includes("REQUIRES_OWNER_OR_ADMIN")
        ? "REQUIRES_OWNER_OR_ADMIN"
        : "RPC_FAILED",
      detail: rpcErr?.message,
    };
  }

  const acceptUrl = `${appOrigin()}/accept-invitation?token=${encodeURIComponent(plain)}`;

  try {
    const admin = createSupabaseAdminClient();
    const { error: inviteErr } = await admin.auth.admin.inviteUserByEmail(
      email,
      {
        data: { invitation_id: invitationId },
        redirectTo: acceptUrl,
      },
    );
    if (inviteErr) {
      // The DB row is persisted; surface the URL so the inviter can pass it
      // out-of-band. Common case: the user already exists; the in-app accept
      // flow still works.
      audit("USER_INVITED", {
        invitation_id: invitationId,
        organization_id: organizationId,
        email,
        delivery: "ADMIN_INVITE_FAILED",
        delivery_detail: inviteErr.message,
        accept_url: acceptUrl,
      });
      return {
        ok: true,
        invitationId: invitationId as string,
      };
    }
  } catch (err) {
    audit("USER_INVITED", {
      invitation_id: invitationId,
      organization_id: organizationId,
      email,
      delivery: "ADMIN_CLIENT_UNAVAILABLE",
      delivery_detail: err instanceof Error ? err.message : String(err),
      accept_url: acceptUrl,
    });
    return { ok: true, invitationId: invitationId as string };
  }

  audit("USER_INVITED", {
    invitation_id: invitationId,
    organization_id: organizationId,
    email,
    delivery: "EMAIL_DISPATCHED",
  });

  revalidatePath("/team");
  return { ok: true, invitationId: invitationId as string };
}

export async function acceptInvitation(
  plainToken: string,
): Promise<({ ok: true; organizationId: string }) | ErrorResult> {
  if (!plainToken) return { ok: false, error: "MISSING_TOKEN" };
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "NOT_AUTHENTICATED" };

  const hash = hashInvitationToken(plainToken);
  const { data, error } = await supabase.rpc("accept_invitation", {
    p_token_hash: hash,
  });
  if (error) {
    audit("INVITATION_ACCEPT_FAILED", {
      user_id: user.id,
      reason: error.message,
    });
    return { ok: false, error: "RPC_FAILED", detail: error.message };
  }
  const row = Array.isArray(data) ? data[0] : data;
  if (!row?.success) {
    audit("INVITATION_ACCEPT_FAILED", {
      user_id: user.id,
      reason: row?.reason,
      organization_id: row?.organization_id,
    });
    return { ok: false, error: row?.reason ?? "RPC_FAILED" };
  }
  audit("INVITATION_ACCEPTED", {
    user_id: user.id,
    organization_id: row.organization_id,
  });
  revalidatePath("/team");
  return { ok: true, organizationId: row.organization_id };
}

export async function revokeInvitation(
  invitationId: string,
): Promise<OkResult | ErrorResult> {
  if (!invitationId) return { ok: false, error: "VALIDATION" };
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "NOT_AUTHENTICATED" };

  const { data: revoked, error } = await supabase.rpc("revoke_invitation", {
    p_invitation_id: invitationId,
  });
  if (error) {
    audit("INVITATION_REVOKE_FAILED", {
      invitation_id: invitationId,
      reason: error.message,
    });
    return { ok: false, error: "RPC_FAILED", detail: error.message };
  }
  if (!revoked) {
    return { ok: false, error: "INVITATION_NOT_PENDING" };
  }
  audit("INVITATION_REVOKED", { invitation_id: invitationId, user_id: user.id });
  revalidatePath("/team");
  return { ok: true };
}

export async function changeMemberRole(input: {
  businessId: string;
  targetUserId: string;
  newRole: string;
  stepUpToken: string;
}): Promise<OkResult | ErrorResult> {
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "NOT_AUTHENTICATED" };

  const { data: ok, error } = await supabase.rpc("change_member_role", {
    p_business_id: input.businessId,
    p_target_user_id: input.targetUserId,
    p_new_role: input.newRole,
    p_step_up_token: input.stepUpToken,
  });
  if (error) {
    audit("MEMBER_ROLE_CHANGE_FAILED", { ...input, reason: error.message });
    const stepUpRejected = error.message.startsWith("MEMBER_STEP_UP_REJECTED");
    return {
      ok: false,
      error: stepUpRejected ? "STEP_UP_REJECTED" : "RPC_FAILED",
      detail: error.message,
    };
  }
  if (!ok) return { ok: false, error: "MEMBER_NOT_FOUND" };
  audit("MEMBER_ROLE_CHANGED", { ...input, by_user_id: user.id });
  revalidatePath("/team");
  return { ok: true };
}

export async function removeMember(input: {
  businessId: string;
  targetUserId: string;
  stepUpToken: string;
}): Promise<OkResult | ErrorResult> {
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return { ok: false, error: "NOT_AUTHENTICATED" };

  const { data: ok, error } = await supabase.rpc("remove_member", {
    p_business_id: input.businessId,
    p_target_user_id: input.targetUserId,
    p_step_up_token: input.stepUpToken,
  });
  if (error) {
    audit("MEMBER_REMOVAL_FAILED", { ...input, reason: error.message });
    return {
      ok: false,
      error: error.message.startsWith("MEMBER_STEP_UP_REJECTED")
        ? "STEP_UP_REJECTED"
        : error.message.includes("MEMBER_CANNOT_REMOVE_OWNER")
          ? "CANNOT_REMOVE_OWNER"
          : error.message.includes("MEMBER_CANNOT_REMOVE_SELF")
            ? "CANNOT_REMOVE_SELF"
            : "RPC_FAILED",
      detail: error.message,
    };
  }
  if (!ok) return { ok: false, error: "MEMBER_NOT_FOUND" };
  audit("MEMBER_REMOVED", { ...input, by_user_id: user.id });
  revalidatePath("/team");
  return { ok: true };
}
