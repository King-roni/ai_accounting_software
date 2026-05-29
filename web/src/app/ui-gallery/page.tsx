"use client";
import { useState } from "react";
import { Plus, Search } from "lucide-react";
import {
  Alert, Badge, Button, Card, CardBody, CardFooter, CardHeader, CardTitle,
  Drawer, EmptyState, ErrorState, Input, Modal, Select, Skeleton, SkeletonText,
  Table, Tabs, Textarea, ToastProvider, useToast, type Column,
} from "@/components/ui";

type Txn = { id: string; date: string; desc: string; amount: number };
const TXNS: Txn[] = [
  { id: "1", date: "2026-05-02", desc: "Revolut card payment", amount: -42.5 },
  { id: "2", date: "2026-05-04", desc: "Client invoice INV-0012", amount: 1800 },
  { id: "3", date: "2026-05-09", desc: "AWS EU-West-1", amount: -213.77 },
];
const COLS: Column<Txn>[] = [
  { id: "date", header: "Date", cell: (r) => r.date, sortable: true, sortValue: (r) => r.date },
  { id: "desc", header: "Description", cell: (r) => r.desc },
  { id: "amount", header: "Amount (€)", numeric: true, sortable: true, sortValue: (r) => r.amount, cell: (r) => r.amount.toFixed(2) },
];

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="flex flex-col gap-3">
      <h2 className="text-xl font-semibold text-text-primary">{title}</h2>
      <div className="flex flex-wrap items-start gap-3">{children}</div>
    </section>
  );
}

function GalleryInner() {
  const { toast } = useToast();
  const [modal, setModal] = useState(false);
  const [drawer, setDrawer] = useState(false);
  const [tab, setTab] = useState("overview");
  const [sel, setSel] = useState<Set<string>>(new Set());

  return (
    <main className="mx-auto flex max-w-5xl flex-col gap-10 p-8">
      <header className="flex flex-col gap-1">
        <h1 className="text-3xl font-bold text-text-primary">Component Library</h1>
        <p className="text-sm text-text-secondary">R1.2 core primitives · design tokens · light/dark</p>
      </header>

      <Section title="Buttons">
        <Button variant="primary">Primary</Button>
        <Button variant="secondary">Secondary</Button>
        <Button variant="tertiary">Tertiary</Button>
        <Button variant="danger">Danger</Button>
        <Button variant="ghost">Ghost</Button>
        <Button leadingIcon={Plus}>With icon</Button>
        <Button loading>Loading</Button>
        <Button disabled>Disabled</Button>
        <Button size="sm">sm</Button>
        <Button size="lg">lg</Button>
      </Section>

      <Section title="Badges">
        <Badge variant="severity-blocking">Blocking</Badge>
        <Badge variant="severity-high">High</Badge>
        <Badge variant="severity-medium">Medium</Badge>
        <Badge variant="severity-low">Low</Badge>
        <Badge variant="status-success">Finalized</Badge>
        <Badge variant="status-info">In progress</Badge>
        <Badge variant="status-neutral">Draft</Badge>
      </Section>

      <Section title="Alerts">
        <div className="flex w-full flex-col gap-2">
          <Alert variant="severity-blocking" title="Finalization blocked">Resolve 3 blocking issues before close.</Alert>
          <Alert variant="status-success" title="Period finalized" onDismiss={() => {}}>April 2026 is locked.</Alert>
          <Alert variant="status-info" title="Heads up">VIES export is queued.</Alert>
        </div>
      </Section>

      <Section title="Cards">
        <Card className="w-64"><CardHeader><CardTitle>Default</CardTitle></CardHeader><CardBody>Plain surface card.</CardBody></Card>
        <Card accent="severity-high" className="w-64"><CardHeader><CardTitle>High severity</CardTitle><Badge variant="severity-high">2</Badge></CardHeader><CardBody>Left-border accent.</CardBody></Card>
        <Card accent="status-success" interactive className="w-64"><CardHeader><CardTitle>Paid</CardTitle></CardHeader><CardBody>Interactive (hover lifts).</CardBody><CardFooter><Button size="sm" variant="tertiary">View</Button></CardFooter></Card>
      </Section>

      <Section title="Form controls">
        <div className="grid w-full max-w-md gap-3">
          <Input label="Email" type="email" placeholder="you@example.com" leadingIcon={Search} helperText="We never share it." />
          <Input label="VAT number" error="Invalid Cyprus VAT format" defaultValue="CY123" />
          <Select label="Period"><option>April 2026</option><option>May 2026</option></Select>
          <Textarea label="Note" placeholder="Optional note…" />
        </div>
      </Section>

      <Section title="Tabs">
        <div className="w-full">
          <Tabs
            value={tab}
            onValueChange={setTab}
            tabs={[
              { id: "overview", label: "Overview", content: <p className="text-sm text-text-secondary">Overview panel.</p> },
              { id: "activity", label: "Activity", content: <p className="text-sm text-text-secondary">Activity panel.</p> },
              { id: "settings", label: "Settings", content: <p className="text-sm text-text-secondary">Settings panel.</p> },
            ]}
          />
        </div>
      </Section>

      <Section title="Table">
        <div className="w-full">
          <Table columns={COLS} data={TXNS} rowKey={(r) => r.id} density="compact" selectable selected={sel} onSelectedChange={setSel} />
        </div>
      </Section>

      <Section title="Overlays & feedback">
        <Button onClick={() => setModal(true)}>Open modal</Button>
        <Button variant="secondary" onClick={() => setDrawer(true)}>Open drawer</Button>
        <Button variant="tertiary" onClick={() => toast({ variant: "success", title: "Saved", description: "Your changes are live." })}>Toast success</Button>
        <Button variant="tertiary" onClick={() => toast({ variant: "error", title: "Failed", description: "Could not reach the server." })}>Toast error</Button>
      </Section>

      <Section title="Loading & empty">
        <div className="w-64"><SkeletonText lines={4} /></div>
        <div className="w-64"><Skeleton height={80} /></div>
        <div className="w-72"><EmptyState heading="No invoices yet" body="Create your first invoice to get started." action={<Button size="sm" leadingIcon={Plus}>New invoice</Button>} /></div>
        <div className="w-72"><ErrorState onRetry={() => {}} /></div>
      </Section>

      <Modal open={modal} onClose={() => setModal(false)} title="Confirm finalization" description="This locks the period." footer={<><Button variant="tertiary" onClick={() => setModal(false)}>Cancel</Button><Button onClick={() => setModal(false)}>Finalize</Button></>}>
        Once finalized, entries become immutable and the archive package is built.
      </Modal>
      <Drawer open={drawer} onClose={() => setDrawer(false)} title="Transaction detail" footer={<Button onClick={() => setDrawer(false)}>Close</Button>}>
        <p>Slide-over panel content. Focus is trapped; Escape closes.</p>
      </Drawer>
    </main>
  );
}

export default function UiGalleryPage() {
  return (
    <ToastProvider>
      <GalleryInner />
    </ToastProvider>
  );
}
