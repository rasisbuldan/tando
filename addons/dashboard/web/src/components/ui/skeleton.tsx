import { cn } from "@/lib/cn";
/** bg-muted, no shimmer; give it the final element's exact size (CLS 0) */
export const Skeleton = ({ className }: { className?: string }) => <div aria-hidden="true" className={cn("rounded-md bg-muted", className)} />;
