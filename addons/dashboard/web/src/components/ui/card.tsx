import { cn } from "@/lib/cn";
export const Card = ({ className, ...p }: React.HTMLAttributes<HTMLDivElement>) => (
  <div className={cn("rounded-lg border border-border bg-card p-4 text-foreground", className)} {...p} />
);
