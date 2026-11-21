import * as React from "react";
import { Slot } from "@radix-ui/react-slot";
import { cn } from "@/lib/cn";

type V = "primary" | "outline" | "ghost" | "destructive";
const VARIANT: Record<V, string> = {
  primary: "bg-primary text-primary-foreground hover:opacity-90",
  outline: "border border-input bg-card text-foreground hover:bg-muted",
  ghost: "text-foreground hover:bg-muted",
  destructive: "bg-destructive text-destructive-foreground hover:opacity-90",
};
export interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> { variant?: V; size?: "sm" | "md" | "icon"; asChild?: boolean }
export const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(({ className, variant = "outline", size = "sm", asChild, ...p }, ref) => {
  const C = asChild ? Slot : "button";
  return <C ref={ref} className={cn("hov inline-flex items-center justify-center gap-2 rounded-md text-[13px] leading-5 font-medium whitespace-nowrap disabled:pointer-events-none disabled:opacity-50",
    size === "sm" ? "h-8 px-3" : size === "md" ? "h-9 px-4" : "h-8 w-8", VARIANT[variant], className)} {...p} />;
});
Button.displayName = "Button";
