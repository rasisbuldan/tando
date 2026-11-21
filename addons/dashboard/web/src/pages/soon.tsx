import { PageHeader, Placeholder, Freshness } from "@/components/panel";
import { overviewPoller, usePoller } from "@/lib/resources";

/** Deploys and Alerts pages (M5) and the unknown route */
export default function Soon({ name, notFound }: { name: string; notFound?: boolean }) {
  const st = usePoller(overviewPoller());
  return (
    <>
      <PageHeader title={name} />
      <Freshness st={st} />
      <div className="mt-4">{notFound ? <p className="m-0 text-[13px] text-muted-foreground">Nothing here. Use the sidebar.</p> : <Placeholder name={name} />}</div>
    </>
  );
}
