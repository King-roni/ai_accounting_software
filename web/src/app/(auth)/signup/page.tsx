import Link from "next/link";
import { signup } from "./actions";

export default function SignupPage() {
  return (
    <div>
      <h2 className="mb-4 text-lg font-medium text-zinc-900 dark:text-zinc-50">
        Create account
      </h2>
      <form action={signup} className="space-y-4">
        <Field name="displayName" label="Display name" type="text" autoComplete="name" required />
        <Field name="email" label="Email" type="email" autoComplete="email" required />
        <Field name="password" label="Password" type="password" autoComplete="new-password" required />
        <p className="text-xs text-zinc-500 dark:text-zinc-400">
          12+ chars, with uppercase, lowercase, digit, and special character.
        </p>
        <button
          type="submit"
          className="w-full rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium text-white hover:bg-zinc-800 disabled:opacity-50 dark:bg-zinc-50 dark:text-zinc-900 dark:hover:bg-zinc-200"
        >
          Create account
        </button>
      </form>
      <p className="mt-6 text-sm text-zinc-500 dark:text-zinc-400">
        Already have an account?{" "}
        <Link href="/login" className="font-medium text-zinc-900 hover:underline dark:text-zinc-50">
          Sign in
        </Link>
      </p>
    </div>
  );
}

function Field(props: {
  name: string;
  label: string;
  type: string;
  autoComplete?: string;
  required?: boolean;
}) {
  return (
    <label className="block">
      <span className="mb-1 block text-sm font-medium text-zinc-700 dark:text-zinc-300">
        {props.label}
      </span>
      <input
        name={props.name}
        type={props.type}
        autoComplete={props.autoComplete}
        required={props.required}
        className="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm shadow-sm focus:border-zinc-500 focus:outline-none focus:ring-1 focus:ring-zinc-500 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-100"
      />
    </label>
  );
}
