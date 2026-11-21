import { cn } from "@/lib/cn";
export const Table = ({ className, ...p }: React.HTMLAttributes<HTMLTableElement>) => <table className={cn("text-[13px] leading-5", className)} {...p} />;
export const Th = ({ className, ...p }: React.ThHTMLAttributes<HTMLTableCellElement>) => (
  <th className={cn("sticky top-0 h-8 bg-card px-3 text-left text-xs leading-4 font-medium text-muted-foreground", className)} {...p} />
);
export const Tr = ({ className, ...p }: React.HTMLAttributes<HTMLTableRowElement>) => (
  <tr className={cn("hov h-9 border-t border-border hover:bg-muted/60", className)} {...p} />
);
export const Td = ({ className, ...p }: React.TdHTMLAttributes<HTMLTableCellElement>) => (
  <td className={cn("overflow-hidden px-3 text-ellipsis whitespace-nowrap", className)} {...p} />
);
