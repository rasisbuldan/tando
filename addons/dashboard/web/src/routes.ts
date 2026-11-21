// lazy routes, prefetched on sidebar hover or focus
import { lazy } from "react";
const imp = {
  overview: () => import("./pages/overview"),
  server: () => import("./pages/server"),
  app: () => import("./pages/app"),
  soon: () => import("./pages/soon"),
  deploys: () => import("./pages/deploys"),
  alerts: () => import("./pages/alerts"),
};
export const Overview = lazy(imp.overview);
export const ServerPage = lazy(imp.server);
export const AppPage = lazy(imp.app);
export const Soon = lazy(imp.soon);
export const DeploysPage = lazy(imp.deploys);
export const AlertsPage = lazy(imp.alerts);
export function prefetchRoute(to: string) {
  if (to === "/") void imp.overview();
  else if (to === "/deploys") void imp.deploys();
  else if (to === "/alerts") void imp.alerts();
  else if (to.startsWith("/s/") && to.split("/").length > 3) void imp.app();
  else if (to.startsWith("/s/")) void imp.server();
  else void imp.soon();
}
