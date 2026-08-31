import { beforeEach, vi } from 'vitest';

beforeEach(() => {
  vi.stubGlobal('fetch', () => {
    throw new Error('unexpected network call in unit tests');
  });
});
