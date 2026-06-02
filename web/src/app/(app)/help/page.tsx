"use client";
import { Placeholder } from "@/components/shell/Placeholder";
import { CircleHelp } from "lucide-react";
// Client component: Placeholder is a client component and `icon` is a Lucide
// component (a function), which cannot be serialized across a Server→Client
// boundary. Rendering this page on the client keeps the icon prop in one runtime.
export default function Page() {
  return <Placeholder title="Help" icon={CircleHelp} blurb="Product help & support resources." />;
}
