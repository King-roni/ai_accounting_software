import { redirect } from "next/navigation";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { createFirstWorkspace } from "./actions";

/**
 * First-run onboarding page (P0.3). Stands outside the (app) shell because the
 * shell needs a business. Auth-gates, sends already-onboarded users to the
 * dashboard, otherwise renders the create-workspace form.
 */
export default async function OnboardingPage({
  searchParams,
}: {
  searchParams: Promise<{ error?: string }>;
}) {
  const supabase = await createSupabaseServerClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/login");

  const { data: businesses } = await supabase
    .from("business_entities")
    .select("id")
    .limit(1);
  if (businesses && businesses.length > 0) redirect("/dashboard");

  const { error } = await searchParams;

  return (
    <div className="flex min-h-screen flex-1 items-center justify-center bg-bg-base px-4 py-12">
      <div className="w-full max-w-md rounded-xl border border-border-default bg-bg-raised p-8 shadow-sm">
        <h1 className="text-xl font-semibold text-text-primary">Set up your workspace</h1>
        <p className="mt-1 text-sm text-text-secondary">
          Create your organization and first business to get started. You can add more
          businesses and invite people later.
        </p>

        <form action={createFirstWorkspace} className="mt-6 space-y-4">
          <Field name="orgName" label="Organization name" required placeholder="Acme Holdings" />
          <Field
            name="businessName"
            label="First business name"
            required
            placeholder="Acme Trading Ltd"
          />
          <div className="grid grid-cols-2 gap-3">
            <Field name="country" label="Country" defaultValue="CY" maxLength={2} />
            <Field name="currency" label="Currency" defaultValue="EUR" maxLength={3} />
          </div>
          <label className="flex items-center gap-2 text-sm text-text-secondary">
            <input type="checkbox" name="vatRegistered" className="rounded border-border-default" />
            VAT registered
          </label>
          <button
            type="submit"
            className="w-full rounded-md bg-action-primary px-4 py-2 text-sm font-medium text-text-on-primary hover:bg-action-hover"
          >
            Create workspace
          </button>
        </form>

        {error && (
          <p className="mt-4 text-sm text-status-danger" role="alert">
            {error}
          </p>
        )}
      </div>
    </div>
  );
}

function Field(props: {
  name: string;
  label: string;
  required?: boolean;
  placeholder?: string;
  defaultValue?: string;
  maxLength?: number;
}) {
  return (
    <label className="block">
      <span className="mb-1 block text-sm font-medium text-text-primary">{props.label}</span>
      <input
        name={props.name}
        required={props.required}
        placeholder={props.placeholder}
        defaultValue={props.defaultValue}
        maxLength={props.maxLength}
        className="w-full rounded-md border border-border-default bg-bg-base px-3 py-2 text-sm text-text-primary shadow-sm focus:border-action-primary focus:outline-none focus:ring-1 focus:ring-action-primary"
      />
    </label>
  );
}
