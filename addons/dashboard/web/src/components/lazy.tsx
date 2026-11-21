// Below-the-fold charts draw only when they come near the viewport (IntersectionObserver), and
// stay drawn after. Until then a placeholder of the card's exact height holds the place (CLS 0).
// Without IntersectionObserver (an old browser, a test) the content draws at once.
import { useEffect, useRef, useState, type ReactNode } from "react";
import { Skeleton } from "./ui/skeleton";
import { cn } from "@/lib/cn";

export function Lazy({ h, children, margin = "300px" }: { h: string; children: ReactNode; margin?: string }) {
  const ref = useRef<HTMLDivElement>(null);
  const [seen, setSeen] = useState(() => typeof IntersectionObserver === "undefined");
  useEffect(() => {
    const el = ref.current;
    if (seen || !el) return;
    const io = new IntersectionObserver((es) => { if (es.some((e) => e.isIntersecting)) { setSeen(true); io.disconnect(); } }, { rootMargin: `${margin} 0px` });
    io.observe(el);
    return () => io.disconnect();
  }, [seen, margin]);
  if (seen) return <>{children}</>;
  return <div ref={ref} aria-busy="true" className={cn("min-w-0", h)}><Skeleton className="size-full" /></div>;
}

/** a section that folds: its charts unmount while it is closed (nothing drawn, nothing observed) */
export function Fold({ title, count, defaultOpen = true, children }: { title: string; count?: number; defaultOpen?: boolean; children: ReactNode }) {
  const [open, setOpen] = useState(defaultOpen);
  return (
    <section className="mb-4" aria-label={title}>
      <button type="button" aria-expanded={open} onClick={() => setOpen((o) => !o)}
        className="hov inset-focus mb-2 flex h-8 w-full items-center gap-2 rounded-md text-left">
        <svg aria-hidden="true" width="12" height="12" viewBox="0 0 12 12" className={cn("shrink-0 text-muted-foreground", open && "rotate-90")}><path d="M4 2l4 4-4 4" fill="none" stroke="currentColor" strokeWidth="1.5" /></svg>
        <h2 className="m-0 text-[15px] leading-[22px] font-semibold">{title}</h2>
        {count != null && <span className="text-xs text-muted-foreground">{count} {count === 1 ? "chart" : "charts"}</span>}
      </button>
      {open && children}
    </section>
  );
}
