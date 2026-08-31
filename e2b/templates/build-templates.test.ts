import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

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

import { BASE_IMAGE_ENV, TEMPLATE_SPECS } from './kodus-template.ts';
import {
  ENV_API_KEY,
  ENV_API_URL,
  ENV_DOMAIN,
  ENV_FORCE,
  EXIT_BUILD_FAILED,
  EXIT_CONFIG,
  EXIT_OK,
  runBuildTemplates,
} from './build-templates.ts';

const LOCAL_API = 'http://127.0.0.1:8080';

function validEnv(overrides: NodeJS.ProcessEnv = {}): NodeJS.ProcessEnv {
  return {
    [ENV_API_KEY]: 'e2b_testkey',
    [ENV_API_URL]: LOCAL_API,
    ...overrides,
  };
}

function lastJsonLine(stdout: string[]): BuildSummary {
  for (let i = stdout.length - 1; i >= 0; i -= 1) {
    const line = stdout[i];
    if (line === undefined) {
      continue;
    }
    try {
      return JSON.parse(line) as BuildSummary;
    } catch {
      continue;
    }
  }
  throw new Error(`no JSON summary in stdout: ${JSON.stringify(stdout)}`);
}

interface BuildSummary {
  templates: Array<{ alias: string; action: string; buildId: string | null }>;
}

function buildCalls(): Array<{ name: string; options: Record<string, unknown> }> {
  return mockTemplate.build.mock.calls.map((call) => {
    const name = call[1];
    const options = call[2];
    if (typeof name !== 'string') {
      throw new Error(`expected Template.build(template, name, options), got name=${String(name)}`);
    }
    if (options === undefined || typeof options !== 'object') {
      throw new Error('expected build options object as the third argument');
    }
    return { name, options: options as Record<string, unknown> };
  });
}

function serializedSdkCalls(): string {
  return JSON.stringify({
    build: mockTemplate.build.mock.calls,
    exists: mockTemplate.exists.mock.calls,
  });
}

describe('runBuildTemplates', () => {
  const stdout: string[] = [];
  const stderr: string[] = [];

  beforeEach(() => {
    stdout.length = 0;
    stderr.length = 0;
    mockBuilder.fromBaseImage.mockReturnValue(mockBuilder);
    mockBuilder.fromImage.mockReturnValue(mockBuilder);
    mockBuilder.aptInstall.mockReturnValue(mockBuilder);
    mockBuilder.runCmd.mockReturnValue(mockBuilder);
    mockBuilder.copy.mockReturnValue(mockBuilder);
    mockBuilder.setStartCmd.mockReturnValue(mockBuilder);
    mockTemplate.mockImplementation(() => mockBuilder);

    mockTemplate.exists.mockResolvedValue(false);
    mockTemplate.build.mockImplementation(async (_template: unknown, name: string) => ({
      name,
      alias: name,
      templateId: `tpl_${name}`,
      buildId: `bld_${name}`,
      tags: [],
    }));

    vi.spyOn(process.stdout, 'write').mockImplementation((chunk: unknown) => {
      stdout.push(String(chunk).replace(/\n$/, ''));
      return true;
    });
    vi.spyOn(process.stderr, 'write').mockImplementation((chunk: unknown) => {
      stderr.push(String(chunk).replace(/\n$/, ''));
      return true;
    });
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  it('builds all three aliases with the spec cpu and memory, base first', async () => {
    const { exitCode, summary } = await runBuildTemplates(validEnv());

    expect(exitCode).toBe(EXIT_OK);
    const calls = buildCalls();
    expect(calls.map((call) => call.name)).toEqual(TEMPLATE_SPECS.map((spec) => spec.alias));
    expect(calls[0]?.name).toBe('base');

    for (const spec of TEMPLATE_SPECS) {
      const call = calls.find((item) => item.name === spec.alias);
      expect(call, spec.alias).toBeDefined();
      expect(call!.options.cpuCount).toBe(spec.cpuCount);
      expect(call!.options.memoryMB).toBe(spec.memoryMB);
      expect(call!.options.apiUrl).toBe(LOCAL_API);
      expect(call!.options.apiKey).toBe('e2b_testkey');
      expect(call!.options.domain).toBeUndefined();
      expect(typeof call!.options.onBuildLogs).toBe('function');
    }

    expect(summary.templates.map((row) => row.action)).toEqual(['built', 'built', 'built']);
    expect(mockBuilder.runCmd).not.toHaveBeenCalled();
    expect(mockBuilder.copy).not.toHaveBeenCalled();
    expect(mockBuilder.setStartCmd).not.toHaveBeenCalled();
  });

  it('skips an existing alias and does not call Template.build for it', async () => {
    mockTemplate.exists.mockImplementation(async (name: string) => name === 'kodus-sandbox');

    const { exitCode, summary } = await runBuildTemplates(validEnv());

    expect(exitCode).toBe(EXIT_OK);
    expect(buildCalls().map((call) => call.name)).toEqual(['base', 'kodus-sandbox-graph']);
    expect(summary.templates).toEqual([
      { alias: 'base', action: 'built', buildId: 'bld_base' },
      { alias: 'kodus-sandbox', action: 'skipped', buildId: null },
      { alias: 'kodus-sandbox-graph', action: 'built', buildId: 'bld_kodus-sandbox-graph' },
    ]);
  });

  it('rebuilds an existing alias when the force flag is set', async () => {
    mockTemplate.exists.mockResolvedValue(true);

    const { exitCode, summary } = await runBuildTemplates(validEnv({ [ENV_FORCE]: 'true' }));

    expect(exitCode).toBe(EXIT_OK);
    const calls = buildCalls();
    expect(calls.map((call) => call.name)).toEqual(TEMPLATE_SPECS.map((spec) => spec.alias));
    for (const call of calls) {
      expect(call.options.skipCache).toBe(true);
    }
    expect(summary.templates.every((row) => row.action === 'built')).toBe(true);
  });

  it('fails closed when E2B_API_KEY is missing and never talks to e2b.app', async () => {
    const { exitCode } = await runBuildTemplates({ [ENV_API_URL]: LOCAL_API });

    expect(exitCode).toBe(EXIT_CONFIG);
    expect(exitCode).not.toBe(EXIT_OK);
    expect(stderr.join('\n')).toContain(ENV_API_KEY);
    expect(mockTemplate.build).not.toHaveBeenCalled();
    expect(mockTemplate.exists).not.toHaveBeenCalled();
    expect(serializedSdkCalls()).not.toContain('e2b.app');
  });

  it('fails closed when API URL and domain are missing and never talks to e2b.app', async () => {
    const { exitCode } = await runBuildTemplates({ [ENV_API_KEY]: 'e2b_testkey' });

    expect(exitCode).toBe(EXIT_CONFIG);
    expect(exitCode).not.toBe(EXIT_OK);
    expect(stderr.join('\n')).toContain(ENV_API_URL);
    expect(stderr.join('\n')).toContain(ENV_DOMAIN);
    expect(mockTemplate.build).not.toHaveBeenCalled();
    expect(mockTemplate.exists).not.toHaveBeenCalled();
    expect(serializedSdkCalls()).not.toContain('e2b.app');
  });

  it('honours the base image override env var', async () => {
    const mirror = 'registry.internal/e2bdev/base@sha256:deadbeef';
    await runBuildTemplates(validEnv({ [BASE_IMAGE_ENV]: mirror }));

    expect(mockBuilder.fromBaseImage).not.toHaveBeenCalled();
    expect(mockBuilder.fromImage).toHaveBeenCalledTimes(TEMPLATE_SPECS.length);
    for (const call of mockBuilder.fromImage.mock.calls) {
      expect(call[0]).toBe(mirror);
    }
  });

  it('prints a well-formed JSON summary of built vs skipped', async () => {
    mockTemplate.exists.mockImplementation(async (name: string) => name === 'base');

    const { exitCode } = await runBuildTemplates(validEnv());
    expect(exitCode).toBe(EXIT_OK);

    const parsed = lastJsonLine(stdout);
    expect(parsed).toEqual({
      templates: [
        { alias: 'base', action: 'skipped', buildId: null },
        { alias: 'kodus-sandbox', action: 'built', buildId: 'bld_kodus-sandbox' },
        { alias: 'kodus-sandbox-graph', action: 'built', buildId: 'bld_kodus-sandbox-graph' },
      ],
    });
  });

  it('returns a non-zero exit distinct from skip when a build fails', async () => {
    mockTemplate.exists.mockResolvedValue(false);
    mockTemplate.build.mockImplementation(async (_template: unknown, name: string) => {
      if (name === 'kodus-sandbox') {
        throw new Error('orchestrator unavailable');
      }
      return {
        name,
        alias: name,
        templateId: `tpl_${name}`,
        buildId: `bld_${name}`,
        tags: [],
      };
    });

    const failed = await runBuildTemplates(validEnv());
    expect(failed.exitCode).toBe(EXIT_BUILD_FAILED);
    expect(failed.exitCode).not.toBe(EXIT_OK);
    expect(failed.summary.templates).toEqual([
      { alias: 'base', action: 'built', buildId: 'bld_base' },
      { alias: 'kodus-sandbox', action: 'failed', buildId: null },
      { alias: 'kodus-sandbox-graph', action: 'built', buildId: 'bld_kodus-sandbox-graph' },
    ]);

    mockTemplate.build.mockImplementation(async (_template: unknown, name: string) => ({
      name,
      alias: name,
      templateId: `tpl_${name}`,
      buildId: `bld_${name}`,
      tags: [],
    }));
    mockTemplate.exists.mockResolvedValue(true);
    const skipped = await runBuildTemplates(validEnv());
    expect(skipped.exitCode).toBe(EXIT_OK);
    expect(failed.exitCode).not.toBe(skipped.exitCode);
  });

  it('accepts E2B_DOMAIN instead of E2B_API_URL', async () => {
    const { exitCode } = await runBuildTemplates({
      [ENV_API_KEY]: 'e2b_testkey',
      [ENV_DOMAIN]: 'e2b.example.com',
    });

    expect(exitCode).toBe(EXIT_OK);
    const calls = buildCalls();
    expect(calls[0]?.options.domain).toBe('e2b.example.com');
    expect(calls[0]?.options.apiUrl).toBeUndefined();
  });
});
