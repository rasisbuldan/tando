import { Suspense, useEffect, useRef, useSyncExternalStore } from "react";
import { Route, Routes, useNavigate } from "react-router";
import { Sidebar, useSidebar } from "./components/sidebar";
import { TooltipProvider } from "./components/ui/tooltip";
import { Loading, PanelBoundary } from "./components/panel";
import { SessionEnded } from "./components/session-ended";
import { overviewPoller, refreshAll, usePoller } from "./lib/resources";
import { sessionStore } from "./lib/api";
import { AppPage, Overview, ServerPage, Soon } from "./routes";

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
      <div className="flex min-h-screen">
        <Sidebar hosts={st.data} sb={sb} version={VERSION} />
        <main id="main" className="min-w-0 flex-1 px-4 pb-8 lg:px-6">
          <div className="max-w-[1440px]">
            <PanelBoundary>
              <Suspense fallback={<div className="h-14 border-b border-border"><Loading h="h-14" /></div>}>
                <Routes>
                  <Route path="/" element={<Overview />} />
                  <Route path="/deploys" element={<Soon name="Deploys" />} />
                  <Route path="/alerts" element={<Soon name="Alerts" />} />
                  <Route path="/s/:host" element={<ServerPage />} />
                  <Route path="/s/:host/:app/:tab?" element={<AppPage />} />
                  <Route path="*" element={<Soon name="Not found" notFound />} />
                </Routes>
              </Suspense>
            </PanelBoundary>
          </div>
        </main>
      </div>
    </TooltipProvider>
  );
}
