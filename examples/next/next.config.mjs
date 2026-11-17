// Standalone output is what tando ships; basePath shows an app served under a sub-path.
export default {
  output: 'standalone',
  basePath: '/demo',
  outputFileTracingRoot: import.meta.dirname,
};
