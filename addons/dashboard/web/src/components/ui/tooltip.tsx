import * as T from "@radix-ui/react-tooltip";

export const TooltipProvider = ({ children }: { children: React.ReactNode }) => <T.Provider delayDuration={300}>{children}</T.Provider>;
/** exact value or full text on hover and focus (opacity only) */
export function Tip({ text, children, side = "top" }: { text: React.ReactNode; children: React.ReactNode; side?: "top" | "right" | "bottom" }) {
  return (
    <T.Root>
      <T.Trigger asChild>{children}</T.Trigger>
      <T.Portal>
        <T.Content side={side} sideOffset={4} className="fade z-50 max-w-80 rounded-md border border-border bg-popover px-2 py-1 text-xs leading-4 font-medium text-foreground shadow-pop">{text}</T.Content>
      </T.Portal>
    </T.Root>
  );
}
