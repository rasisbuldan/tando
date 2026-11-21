import * as D from "@radix-ui/react-dropdown-menu";
import { cn } from "@/lib/cn";
export const Menu = D.Root;
export const MenuTrigger = D.Trigger;
export const MenuContent = ({ className, ...p }: React.ComponentProps<typeof D.Content>) => (
  <D.Portal><D.Content sideOffset={4} className={cn("pop z-50 min-w-36 rounded-lg border border-border bg-popover p-1 shadow-pop", className)} {...p} /></D.Portal>
);
export const MenuItem = ({ className, ...p }: React.ComponentProps<typeof D.Item>) => (
  <D.Item className={cn("flex h-8 cursor-pointer items-center gap-2 rounded-md px-2 text-[13px] leading-5 outline-none data-[highlighted]:bg-muted", className)} {...p} />
);
