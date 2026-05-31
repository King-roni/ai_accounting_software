"use server";

/**
 * First-run onboarding (P0.3). A freshly-signed-up user has a public.users row
 * but no organization/business, so they land here. createFirstWorkspace calls
 * the bootstrap RPCs (create_organization → create_business, which assigns the
 * user OWNER and loads the default Cyprus chart) as the authenticated user, then
 * redirects to the dashboard.
 */
import { redirect } from "next/navigation";
import { createSupabaseServerClient } from "@/lib/supabase/server";

export async function createFirstWorkspace(formData: FormData) {
  const orgName = String(formData.get("orgName") ?? "").trim();
  const businessName = String(formData.get("businessName") ?? "").trim();
  const country = (String(formData.get("country") ?? "CY").trim().toUpperCase() || "CY").slice(0, 2);
  const currency = (String(formData.get("currency") ?? "EUR").trim().toUpperCase() || "EUR").slice(0, 3);
  const vatRegistered = formData.get("vatRegistered") === "on";

  const fail = (msg: string): never =>
    redirect(`/onboarding?error=${encodeURIComponent(msg)}`);

  if (!orgName || !businessName) fail("Organization and business name are required.");

  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: orgRaw, error: orgErr } = await supabase.rpc("create_organization", {
    p_name: orgName,
  });
  if (orgErr) fail(orgErr.message);
  const org = orgRaw as { ok?: boolean; organization_id?: string; reason?: string };
  if (!org?.ok || !org.organization_id) fail(org?.reason ?? "Could not create organization.");

  const { data: bizRaw, error: bizErr } = await supabase.rpc("create_business", {
    p_organization_id: org.organization_id,
    p_display_name: businessName,
    p_country_code: country,
    p_currency: currency,
    p_vat_registered: vatRegistered,
  });
  if (bizErr) fail(bizErr.message);
  const biz = bizRaw as { ok?: boolean; business_id?: string; reason?: string };
  if (!biz?.ok || !biz.business_id) fail(biz?.reason ?? "Could not create business.");

  redirect("/dashboard");
}
