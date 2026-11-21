import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { fileURLToPath } from "node:url";

const out = fileURLToPath(new URL("../server/webdist/dist", import.meta.url));

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: { alias: { "@": fileURLToPath(new URL("./src", import.meta.url)) } },
  // public/ holds theme.js and favicon.svg: copied as they are (theme.js must stay a file of its own)
  build: {
    outDir: out,
    emptyOutDir: true,
    assetsInlineLimit: 0, // nothing inlined: the CSP allows no inline script or style
    cssCodeSplit: true,
    sourcemap: false,
    chunkSizeWarningLimit: 600,
  },
  server: { proxy: { "/api": process.env.TANDO_DASH_URL || "http://127.0.0.1:8099", "/open": process.env.TANDO_DASH_URL || "http://127.0.0.1:8099" } },
  test: { environment: "node", include: ["src/**/*.test.ts"] },
});
