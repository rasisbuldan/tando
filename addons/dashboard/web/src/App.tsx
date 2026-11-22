import { Suspense, useEffect, useRef, useSyncExternalStore } from "react";
import { Route, Routes, useNavigate } from "react-router";
import { Sidebar, useSidebar } from "./components/sidebar";
import { TooltipProvider } from "./components/ui/tooltip";
import { Loading, PanelBoundary } from "./components/panel";
import { SessionEnded } from "./components/session-ended";
import { overviewPoller, refreshAll, usePoller } from "./lib/resources";
import { sessionStore } from "./lib/api";
import { StudioNotice } from "./components/studio";
import { AlertsPage, AppPage, DeploysPage, Overview, ServerPage, Soon } from "./routes";

const VERSION = "tando dashboard";

function typing(t: EventTarget | null): boolean {
  const e = t as HTMLElement | null;
  return !!e && (e.tagName === "INPUT" || e.tagName === "TEXTAREA" || e.tagName === "SELECT" || e.isContentEditable);
}

export function App() {
  const ended = useSyncExternalStore(sessionStore.subscribe, sessionStore.get);
  if (ended) return <SessionEnded />;
  return <Shell />;
}

function Shell() {
  const sb = useSidebar();
  const nav = useNavigate();
  const st = usePoller(overviewPoller());
  const g = useRef(0);
  // a write this tab started before a reload: find it by its key and show it again
  useEffect(() => { void import("./lib/actions").then((m) => m.actions().reattach()); }, []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.metaKey || e.ctrlKey || e.altKey || typing(e.target)) return;
      if (g.current && Date.now() - g.current < 1500) {
        g.current = 0;
        const to = ({ o: "/", d: "/deploys", a: "/alerts" } as Record<string, string>)[e.key];
        if (to) { e.preventDefault(); nav(to); return; }
      }
      if (e.key === "g") g.current = Date.now();
      else if (e.key === "[") sb.toggle();
      else if (e.key === "r") refreshAll();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [nav, sb]);

  return (
    <TooltipProvider>
      <a href="#main" className="skip">Skip to content</a>
      <div className="flex h-dvh overflow-hidden">
        <Sidebar hosts={st.data} sb={sb} version={VERSION} />
        <main id="main" tabIndex={-1} className="h-full min-w-0 flex-1 overflow-y-auto overscroll-none px-4 pb-8 outline-none lg:px-6">
          <div className="max-w-[1440px]">
            <PanelBoundary>
              <Suspense fallback={<div className="h-14 border-b border-border"><Loading h="h-14" /></div>}>
                <Routes>
                  <Route path="/" element={<Overview />} />
                  <Route path="/deploys" element={<DeploysPage />} />
                  <Route path="/alerts" element={<AlertsPage />} />
                  <Route path="/s/:host" element={<ServerPage />} />
                  <Route path="/s/:host/:app/:tab?" element={<AppPage />} />
                  <Route path="*" element={<Soon name="Not found" notFound />} />
                </Routes>
              </Suspense>
            </PanelBoundary>
          </div>
        </main>
      </div>
      <StudioNotice />
    </TooltipProvider>
  );
}
