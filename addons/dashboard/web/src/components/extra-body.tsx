import type { ReactNode } from "react";
import { Empty, Loading, SectionError } from "./panel";
import { extraError } from "@/lib/extra";
import { refreshAll } from "@/lib/resources";
import type { PollState } from "@/lib/poller";
import { fmtTime } from "@/lib/format";

/** body of a section fed by a poller: data, or one error line with Retry, or a skeleton; stale data keeps showing */
export function ExtraBody<T>({ st, what, h = "h-32", children }: { st: PollState<T>; what: string; h?: string; children: (d: T) => ReactNode }) {
  if (st.data) {
    return (
      <>
        {st.error && <p className="m-0 mb-2 text-xs text-muted-foreground">{`Data from ${fmtTime(st.fetchedAtS)}, retrying: ${extraError(st.error, what)}`}</p>}
        {children(st.data)}
      </>
    );
  }
  if (st.error) return <SectionError message={extraError(st.error, what) ?? "Could not read."} onRetry={refreshAll} />;
  return <Loading h={h} />;
}
export const EmptyLine = Empty;
