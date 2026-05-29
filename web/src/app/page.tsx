import { redirect } from "next/navigation";

// Root → the authenticated dashboard shell. The (app) layout gates auth and
// redirects unauthenticated users to /login.
export default function Home() {
  redirect("/dashboard");
}
