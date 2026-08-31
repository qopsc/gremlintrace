import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';

import { Template, type LogEntry } from 'e2b';

import {
  createTemplate,
  resolveBaseImage,
  TEMPLATE_SPECS,
  type TemplateSpec,
} from './kodus-template.ts';

export const ENV_API_KEY = 'E2B_API_KEY';
export const ENV_API_URL = 'E2B_API_URL';
export const ENV_DOMAIN = 'E2B_DOMAIN';
export const ENV_FORCE = 'E2B_TEMPLATE_FORCE';

export const EXIT_OK = 0;
export const EXIT_BUILD_FAILED = 1;
export const EXIT_CONFIG = 2;

export type TemplateAction = 'built' | 'skipped' | 'failed';

export interface TemplateResult {
  alias: string;
  action: TemplateAction;
  buildId: string | null;
}

export interface BuildSummary {
  templates: TemplateResult[];
}

export class ConfigError extends Error {
  readonly missing: readonly string[];

  constructor(message: string, missing: readonly string[]) {
    super(message);
    this.name = 'ConfigError';
    this.missing = missing;
  }
}

export interface ConnectionOpts {
  apiKey: string;
  apiUrl?: string;
  domain?: string;
}

export function isForceEnabled(env: NodeJS.ProcessEnv): boolean {
  const raw = env[ENV_FORCE];
  if (raw === undefined) {
    return false;
  }
  return ['1', 'true', 'yes'].includes(raw.trim().toLowerCase());
}

export function parseConnection(env: NodeJS.ProcessEnv): ConnectionOpts {
  const apiKey = env[ENV_API_KEY]?.trim();
  if (!apiKey) {
    throw new ConfigError(
      `Missing ${ENV_API_KEY}. Set it to the E2B team API key (e2b_…) from /etc/qops/secrets.env. ` +
        `Refusing to build: without an explicit key the SDK would send the request to E2B cloud.`,
      [ENV_API_KEY],
    );
  }

  const apiUrl = env[ENV_API_URL]?.trim() || undefined;
  const domain = env[ENV_DOMAIN]?.trim() || undefined;
  if (!apiUrl && !domain) {
    throw new ConfigError(
      `Missing ${ENV_API_URL} or ${ENV_DOMAIN}. ` +
        `Set ${ENV_API_URL}=http://127.0.0.1:8080 for local template builds. ` +
        `Refusing to default to e2b.app (E2B cloud).`,
      [ENV_API_URL, ENV_DOMAIN],
    );
  }

  return {
    apiKey,
    ...(apiUrl ? { apiUrl } : {}),
    ...(domain ? { domain } : {}),
  };
}

export function streamBuildLog(entry: LogEntry): void {
  process.stdout.write(`${entry.message}\n`);
}

function printSummary(summary: BuildSummary): void {
  process.stdout.write(`${JSON.stringify(summary)}\n`);
}

async function buildOne(
  spec: TemplateSpec,
  baseImage: string,
  connection: ConnectionOpts,
  force: boolean,
): Promise<TemplateResult> {
  const exists = await Template.exists(spec.alias, connection);
  if (exists && !force) {
    process.stderr.write(`skip ${spec.alias}: alias already exists\n`);
    return { alias: spec.alias, action: 'skipped', buildId: null };
  }

  if (exists && force) {
    process.stderr.write(`rebuild ${spec.alias}: ${ENV_FORCE} is set\n`);
  } else {
    process.stderr.write(`build ${spec.alias}\n`);
  }

  const template = createTemplate(spec, baseImage);
  const info = await Template.build(template, spec.alias, {
    ...connection,
    cpuCount: spec.cpuCount,
    memoryMB: spec.memoryMB,
    skipCache: force,
    onBuildLogs: streamBuildLog,
  });

  return { alias: spec.alias, action: 'built', buildId: info.buildId };
}

export async function runBuildTemplates(
  env: NodeJS.ProcessEnv,
): Promise<{ exitCode: number; summary: BuildSummary }> {
  let connection: ConnectionOpts;
  try {
    connection = parseConnection(env);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    process.stderr.write(`${message}\n`);
    const summary: BuildSummary = { templates: [] };
    printSummary(summary);
    return { exitCode: EXIT_CONFIG, summary };
  }

  const force = isForceEnabled(env);
  const baseImage = resolveBaseImage(env);
  const results: TemplateResult[] = [];
  let failed = false;

  for (const spec of TEMPLATE_SPECS) {
    try {
      results.push(await buildOne(spec, baseImage, connection, force));
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      process.stderr.write(`build failed for ${spec.alias}: ${message}\n`);
      results.push({ alias: spec.alias, action: 'failed', buildId: null });
      failed = true;
    }
  }

  const summary: BuildSummary = { templates: results };
  printSummary(summary);
  return { exitCode: failed ? EXIT_BUILD_FAILED : EXIT_OK, summary };
}

export async function main(env: NodeJS.ProcessEnv = process.env): Promise<number> {
  const { exitCode } = await runBuildTemplates(env);
  return exitCode;
}

function isMain(): boolean {
  const entry = process.argv[1];
  if (!entry) {
    return false;
  }
  return import.meta.url === pathToFileURL(resolve(entry)).href;
}

if (isMain()) {
  void main()
    .then((code) => {
      process.exit(code);
    })
    .catch((err: unknown) => {
      const message = err instanceof Error ? err.message : String(err);
      process.stderr.write(`${message}\n`);
      process.exit(EXIT_BUILD_FAILED);
    });
}
