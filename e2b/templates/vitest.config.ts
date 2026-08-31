import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    environment: 'node',
    clearMocks: true,
    unstubEnvs: true,
    setupFiles: ['./vitest.setup.ts'],
  },
});
