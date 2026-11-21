import { LogViewer } from "@/components/log-viewer";
import { PanelBoundary } from "@/components/panel";

export default function LogsTab({ host, app, releases }: { host: string; app: string; releases: string[] }) {
  return <PanelBoundary minH="min-h-[400px]"><LogViewer host={host} app={app} releases={releases} /></PanelBoundary>;
}
