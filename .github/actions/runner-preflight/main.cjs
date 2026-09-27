require('../../../scripts/build/recover-runner.cjs').recover().catch(() => {
  console.warn('Runner preflight: recovery unavailable; continuing without automatic cleanup.');
});
