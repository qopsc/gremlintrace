import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { describe, expect, it } from 'vitest';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, '../..');

describe('e2b SDK pin', () => {
  it('package.json e2b version matches versions.yml e2b_sdk_version', () => {
    const versions = readFileSync(join(repoRoot, 'versions.yml'), 'utf8');
    const match = versions.match(/^e2b_sdk_version:\s*"([^"]+)"\s*$/m);
    expect(match?.[1], 'versions.yml must define e2b_sdk_version').toBeDefined();

    const pkg = JSON.parse(readFileSync(join(here, 'package.json'), 'utf8')) as {
      dependencies?: { e2b?: string };
    };
    expect(pkg.dependencies?.e2b).toBe(match![1]);
  });
});
