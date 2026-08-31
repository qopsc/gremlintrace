import { beforeEach, describe, expect, it, vi } from 'vitest';

const { mockBuilder, mockTemplate } = vi.hoisted(() => {
  const mockBuilder = {
    fromBaseImage: vi.fn(),
    fromImage: vi.fn(),
    aptInstall: vi.fn(),
    runCmd: vi.fn(),
    copy: vi.fn(),
    setStartCmd: vi.fn(),
  };
  mockBuilder.fromBaseImage.mockReturnValue(mockBuilder);
  mockBuilder.fromImage.mockReturnValue(mockBuilder);
  mockBuilder.aptInstall.mockReturnValue(mockBuilder);
  mockBuilder.runCmd.mockReturnValue(mockBuilder);
  mockBuilder.copy.mockReturnValue(mockBuilder);
  mockBuilder.setStartCmd.mockReturnValue(mockBuilder);

  const mockTemplate = Object.assign(vi.fn(() => mockBuilder), {
    build: vi.fn(),
    exists: vi.fn(),
  });

  return { mockBuilder, mockTemplate };
});

vi.mock('e2b', () => ({
  Template: mockTemplate,
  waitForPort: vi.fn(),
}));

import {
  BASE_IMAGE_ENV,
  createTemplate,
  DEFAULT_BASE_IMAGE,
  resolveBaseImage,
  TEMPLATE_ALIASES,
  TEMPLATE_SPECS,
} from './kodus-template.ts';

describe('TEMPLATE_SPECS', () => {
  it('defines the three spec aliases with cpu and memory', () => {
    expect(TEMPLATE_SPECS).toEqual([
      { alias: 'base', cpuCount: 2, memoryMB: 512, aptPackages: [] },
      { alias: 'kodus-sandbox', cpuCount: 2, memoryMB: 1024, aptPackages: ['git', 'ripgrep'] },
      {
        alias: 'kodus-sandbox-graph',
        cpuCount: 2,
        memoryMB: 2560,
        aptPackages: ['git', 'ripgrep'],
      },
    ]);
    expect(TEMPLATE_ALIASES).toEqual(['base', 'kodus-sandbox', 'kodus-sandbox-graph']);
  });

  it('lists base first', () => {
    expect(TEMPLATE_SPECS[0]?.alias).toBe('base');
  });
});

describe('resolveBaseImage', () => {
  it(`defaults to ${DEFAULT_BASE_IMAGE} without a :latest tag`, () => {
    expect(DEFAULT_BASE_IMAGE).toBe('e2bdev/base');
    expect(DEFAULT_BASE_IMAGE.includes(':latest')).toBe(false);
    expect(resolveBaseImage({})).toBe(DEFAULT_BASE_IMAGE);
  });

  it(`honours ${BASE_IMAGE_ENV}`, () => {
    expect(
      resolveBaseImage({ [BASE_IMAGE_ENV]: 'registry.example.com/e2bdev/base@sha256:abc' }),
    ).toBe('registry.example.com/e2bdev/base@sha256:abc');
  });

  it(`treats empty ${BASE_IMAGE_ENV} as the default`, () => {
    expect(resolveBaseImage({ [BASE_IMAGE_ENV]: '  ' })).toBe(DEFAULT_BASE_IMAGE);
  });
});

function wireBuilder(): void {
  mockBuilder.fromBaseImage.mockReturnValue(mockBuilder);
  mockBuilder.fromImage.mockReturnValue(mockBuilder);
  mockBuilder.aptInstall.mockReturnValue(mockBuilder);
  mockBuilder.runCmd.mockReturnValue(mockBuilder);
  mockBuilder.copy.mockReturnValue(mockBuilder);
  mockBuilder.setStartCmd.mockReturnValue(mockBuilder);
  mockTemplate.mockImplementation(() => mockBuilder);
}

describe('createTemplate', () => {
  beforeEach(() => {
    wireBuilder();
  });

  it('uses fromBaseImage for the default image and does not apt-install on base', () => {
    const spec = TEMPLATE_SPECS.find((item) => item.alias === 'base');
    expect(spec).toBeDefined();
    createTemplate(spec!, DEFAULT_BASE_IMAGE);

    expect(mockTemplate).toHaveBeenCalledOnce();
    expect(mockBuilder.fromBaseImage).toHaveBeenCalledOnce();
    expect(mockBuilder.fromImage).not.toHaveBeenCalled();
    expect(mockBuilder.aptInstall).not.toHaveBeenCalled();
  });

  it('apt-installs git and ripgrep on kodus templates', () => {
    const spec = TEMPLATE_SPECS.find((item) => item.alias === 'kodus-sandbox');
    expect(spec).toBeDefined();
    createTemplate(spec!, DEFAULT_BASE_IMAGE);

    expect(mockBuilder.fromBaseImage).toHaveBeenCalledOnce();
    expect(mockBuilder.aptInstall).toHaveBeenCalledExactlyOnceWith(['git', 'ripgrep']);
  });

  it('honours a mirrored base image via fromImage', () => {
    const spec = TEMPLATE_SPECS.find((item) => item.alias === 'kodus-sandbox-graph');
    expect(spec).toBeDefined();
    const mirror = 'ghcr.io/example/e2bdev-base:pinned';
    createTemplate(spec!, mirror);

    expect(mockBuilder.fromBaseImage).not.toHaveBeenCalled();
    expect(mockBuilder.fromImage).toHaveBeenCalledExactlyOnceWith(mirror);
    expect(mockBuilder.aptInstall).toHaveBeenCalledExactlyOnceWith(['git', 'ripgrep']);
  });

  it('never calls shadowsocks runCmd, copy, or setStartCmd', () => {
    for (const spec of TEMPLATE_SPECS) {
      createTemplate(spec, DEFAULT_BASE_IMAGE);
      createTemplate(spec, 'mirror.example/e2bdev/base:1');
    }

    expect(mockBuilder.runCmd).not.toHaveBeenCalled();
    expect(mockBuilder.copy).not.toHaveBeenCalled();
    expect(mockBuilder.setStartCmd).not.toHaveBeenCalled();
  });
});
