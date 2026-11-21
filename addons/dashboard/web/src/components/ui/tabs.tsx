import * as T from "@radix-ui/react-tabs";
import { cn } from "@/lib/cn";
/** range switch (1h/24h/7d): segmented, controlled */
export function RangeTabs<V extends string>({ value, onChange, items, label }: { value: V; onChange: (v: V) => void; items: V[]; label: string }) {
  return (
    <T.Root value={value} onValueChange={(v) => onChange(v as V)}>
      <T.List aria-label={label} className="inline-flex h-8 items-center gap-0.5 rounded-md border border-input bg-card p-0.5">
        {items.map((i) => (
          <T.Trigger key={i} value={i} className={cn("hov h-6 rounded-sm px-3 text-[13px] leading-5 font-medium", value === i ? "bg-primary text-primary-foreground" : "text-muted-foreground hover:bg-muted")}>{i}</T.Trigger>
        ))}
      </T.List>
    </T.Root>
  );
}
