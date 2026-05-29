import { redirect } from "next/navigation";

import { createSupabaseServerClient } from "@/lib/supabase/server";
import { acceptInvitation } from "@/app/(team)/team/actions";

const REASON_COPY: Record<string, string> = {
  NOT_AUTHENTICATED: "Please sign in to accept the invitation.",
  INVITATION_NOT_FOUND: "This invitation link is not recognized.",
  INVITATION_REVOKED: "This invitation has been revoked by the organization owner.",
  INVITATION_ALREADY_ACCEPTED: "This invitation has already been accepted.",
  INVITATION_EXPIRED: "This invitation has expired.",
  INVITATION_EMAIL_MISMATCH:
    "This invitation was sent to a different email. Sign out and sign in with the invited address.",
  MISSING_TOKEN: "The invitation link is missing its token.",
  RPC_FAILED: "We couldn't process the invitation. Try again or contact the inviter.",
};

export default async function AcceptInvitationPage(props: {
  searchParams: Promise<{ token?: string }>;
}) {
  const { token } = await props.searchParams;

  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    redirect(`/login?next=${encodeURIComponent(`/accept-invitation?token=${token ?? ""}`)}`);
  }

  if (!token) {
    return (
      <div className="mx-auto max-w-md p-6">
        <h1 className="text-xl font-medium">Invitation</h1>
        <p className="mt-3 text-sm text-red-700">{REASON_COPY.MISSING_TOKEN}</p>
      </div>
    );
  }

  const result = await acceptInvitation(token);
  if (result.ok) {
    redirect("/?invited=1");
  }

  return (
    <div className="mx-auto max-w-md space-y-3 p-6">
      <h1 className="text-xl font-medium">Invitation</h1>
      <p className="text-sm text-red-700">
        {REASON_COPY[result.error] ?? `Could not accept invitation: ${result.error}`}
      </p>
      <p className="text-xs text-zinc-500">{result.detail ?? ""}</p>
    </div>
  );
}
