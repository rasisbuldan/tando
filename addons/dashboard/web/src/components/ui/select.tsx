import { cn } from "@/lib/cn";
/** a native select with our tokens (32 px, input border); options are [value, label] */
export function Select({ label, value, onChange, options, className, disabled }: {
  label: string; value: string; onChange: (v: string) => void; options: [string, string][]; className?: string; disabled?: boolean;
}) {
  return (
    <select aria-label={label} value={value} disabled={disabled} onChange={(e) => onChange(e.target.value)}
      className={cn("hov h-8 max-w-full min-w-0 rounded-md border border-input bg-card px-2 text-[13px] leading-5 text-foreground disabled:opacity-50", className)}>
      {options.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
    </select>
  );
}
/** a 32 px text input */
export function Input({ className, ...p }: React.ComponentProps<"input">) {
  return <input className={cn("h-8 min-w-0 rounded-md border border-input bg-card px-2 text-[13px] leading-5 text-foreground placeholder:text-muted-foreground", className)} {...p} />;
}
/** a pressed/unpressed button (aria-pressed), 32 px */
export function Toggle({ pressed, onPressedChange, children, disabled, title }: { pressed: boolean; onPressedChange: (b: boolean) => void; children: React.ReactNode; disabled?: boolean; title?: string }) {
  return (
    <button type="button" aria-pressed={pressed} disabled={disabled} title={title} onClick={() => onPressedChange(!pressed)}
      className={cn("hov inline-flex h-8 items-center gap-2 rounded-md border px-3 text-[13px] leading-5 font-medium whitespace-nowrap disabled:pointer-events-none disabled:opacity-50",
        pressed ? "border-primary bg-primary text-primary-foreground" : "border-input bg-card text-foreground hover:bg-muted")}>{children}</button>
  );
}
