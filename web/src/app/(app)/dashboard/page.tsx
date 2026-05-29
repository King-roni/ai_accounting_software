"use client";
import { Building2, RefreshCw } from "lucide-react";
import { Button, Card, CardBody, CardHeader, CardTitle, EmptyState } from "@/components/ui";
import { formatPeriod, useShell } from "@/components/shell/ShellContext";

// The 11 default dashboard cards land in R2.8 (B16·P06–P11). Until then the
// dashboard shows the shell context + placeholders for each card slot.
const CARD_SLOTS = [
  "Monthly Overview", "Income", "Expenses", "Missing Documents",
  "Review Issues", "VAT Summary", "Subscriptions", "Team Costs",
  "Client Invoices", "Cash Movement", "Finalized Periods",
];

export default function DashboardPage() {
  const { currentBusiness, isMultiBusiness, period } = useShell();
  const heading = isMultiBusiness ? "Multi-business overview" : currentBusiness?.display_name ?? "Dashboard";

  return (
    <div className="flex flex-col gap-5">
      <header className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold text-text-primary">{heading}</h1>
          <p className="text-sm text-text-secondary tabular-nums">{formatPeriod(period)}</p>
        </div>
        <Button variant="secondary" size="sm" leadingIcon={RefreshCw}>Refresh now</Button>
      </header>

      {!currentBusiness && !isMultiBusiness ? (
        <EmptyState
          icon={Building2}
          heading="No businesses yet"
          body="Once you have access to a business, its dashboard appears here."
        />
      ) : (
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-3">
          {CARD_SLOTS.map((name) => (
            <Card key={name}>
              <CardHeader><CardTitle>{name}</CardTitle></CardHeader>
              <CardBody>Card lands in R2.8 — wired to the seeded dashboard_card_definitions.</CardBody>
            </Card>
          ))}
        </div>
      )}
    </div>
  );
}
