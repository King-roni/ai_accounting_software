import { resetPassword } from "./actions";

export default function ResetPasswordPage() {
  return (
    <div>
      <h2 className="mb-4 text-lg font-medium text-zinc-900 dark:text-zinc-50">
        Choose a new password
      </h2>
      <form action={resetPassword} className="space-y-4">
        <Field name="password" label="New password" autoComplete="new-password" />
        <Field name="confirm" label="Confirm new password" autoComplete="new-password" />
        <p className="text-xs text-zinc-500 dark:text-zinc-400">
          12+ chars, with uppercase, lowercase, digit, and special character.
        </p>
        <button
          type="submit"
          className="w-full rounded-md bg-action-primary px-4 py-2 text-sm font-medium text-text-on-primary hover:bg-action-hover"
        >
          Update password
        </button>
      </form>
    </div>
  );
}

function Field(props: { name: string; label: string; autoComplete: string }) {
  return (
    <label className="block">
      <span className="mb-1 block text-sm font-medium text-zinc-700 dark:text-zinc-300">
        {props.label}
      </span>
      <input
        name={props.name}
        type="password"
        autoComplete={props.autoComplete}
        required
        className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm shadow-sm focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-500 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-100"
      />
    </label>
  );
}
