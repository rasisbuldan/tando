import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';
/** @type {import('next').NextConfig} */
export default {
  output: 'standalone',
  poweredByHeader: false,
  outputFileTracingRoot: dirname(fileURLToPath(import.meta.url)),
};
