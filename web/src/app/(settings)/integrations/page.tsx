import { redirect } from "next/navigation";

import { createSupabaseServerClient } from "@/lib/supabase/server";
import IntegrationCard from "./IntegrationCard";

type IntegrationRow = {
  id: string;
  business_id: string;
  provider: "GMAIL" | "GOOGLE_DRIVE";
  status: "ACTIVE" | "DISCONNECTED" | "ERROR";
  scope: string[];
  connected_at: string;
  last_refreshed_at: string | null;
  access_token_expires_at: string | null;
  last_error: string | null;
};

type BusinessRow = { id: string; display_name: string; organization_id: string };

type DriveMappingRow = {
  business_id: string;
  root_folder_id: string;
  root_folder_name: string | null;
};

export default async function IntegrationsPage(props: {
  searchParams: Promise<{ error?: string; connected?: string }>;
}) {
  const { error, connected } = await props.searchParams;

  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const [{ data: businesses }, { data: integrations }, { data: driveMappings }] =
    await Promise.all([
      supabase
        .from("business_entities")
        .select("id, display_name, organization_id")
        .order("display_name", { ascending: true }),
      supabase
        .from("business_integrations")
        .select(
          "id, business_id, provider, status, scope, connected_at, last_refreshed_at, access_token_expires_at, last_error",
        ),
      supabase
        .from("drive_folder_mappings")
        .select("business_id, root_folder_id, root_folder_name"),
    ]);

  const byBusiness = new Map<string, { biz: BusinessRow; rows: IntegrationRow[] }>();
  for (const b of (businesses as BusinessRow[] | null) ?? []) {
    byBusiness.set(b.id, { biz: b, rows: [] });
  }
  for (const r of (integrations as IntegrationRow[] | null) ?? []) {
    byBusiness.get(r.business_id)?.rows.push(r);
  }
  const mappingByBusiness = new Map(
    ((driveMappings as DriveMappingRow[] | null) ?? []).map((m) => [m.business_id, m]),
  );

  return (
    <div className="mx-auto max-w-4xl space-y-6 p-6">
      <header>
        <h1 className="text-xl font-medium text-zinc-900 dark:text-zinc-50">
          Integrations
        </h1>
        <p className="mt-1 text-sm text-zinc-500">
          Connect Gmail and Google Drive for document intake. Read-only access only.
        </p>
      </header>

      {error && (
        <div className="rounded-md border border-red-300 bg-red-50 p-3 text-sm text-red-800 dark:border-red-700 dark:bg-red-950 dark:text-red-200">
          {error === "OAUTH_NOT_CONFIGURED"
            ? "Google OAuth is not configured in this environment. Set GOOGLE_OAUTH_CLIENT_ID / GOOGLE_OAUTH_CLIENT_SECRET."
            : `Could not complete integration: ${error}`}
        </div>
      )}
      {connected && (
        <div className="rounded-md border border-green-300 bg-green-50 p-3 text-sm text-green-800 dark:border-green-700 dark:bg-green-950 dark:text-green-200">
          Connected {connected.replace("_", " ").toLowerCase()} successfully.
        </div>
      )}

      {byBusiness.size === 0 && (
        <p className="text-sm text-zinc-500">No businesses available.</p>
      )}

      {Array.from(byBusiness.entries()).map(([bizId, { biz, rows }]) => {
        const gmail = rows.find((r) => r.provider === "GMAIL");
        const drive = rows.find((r) => r.provider === "GOOGLE_DRIVE");
        const mapping = mappingByBusiness.get(bizId);
        return (
          <section
            key={bizId}
            className="space-y-3 rounded-lg border border-zinc-200 p-4 dark:border-zinc-800"
          >
            <h2 className="text-base font-medium text-zinc-900 dark:text-zinc-50">
              {biz.display_name}
            </h2>
            <div className="grid gap-3 sm:grid-cols-2">
              <IntegrationCard
                businessId={bizId}
                provider="GMAIL"
                integration={gmail}
              />
              <IntegrationCard
                businessId={bizId}
                provider="GOOGLE_DRIVE"
                integration={drive}
                driveMapping={mapping}
              />
            </div>
          </section>
        );
      })}
    </div>
  );
}
