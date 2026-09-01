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
  templateId: string | null;
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
  apiUrl: string;
  domain?: string;
}

export function isForceEnabled(env: NodeJS.ProcessEnv): boolean {
  const raw = env[ENV_FORCE];
  if (raw === undefined) {
    return false;
  }
  return ['1', 'true', 'yes'].includes(raw.trim().toLowerCase());
}

const E2B_CLOUD_ROOT = 'e2b.app';

/**
 * A hostname targets E2B Cloud iff, after lowercasing and stripping a trailing
 * DNS dot, it is exactly `e2b.app` or a DNS child of that apex
 * (`host === 'e2b.app' || host.endsWith('.e2b.app')`).
 *
 * The comparison is against `URL.hostname` (or a bare domain parsed through
 * `new URL`) only — never against the raw string — so a query like
 * `https://evil.com/?x=e2b.app` is not Cloud, and
 * `https://api.e2b.app.customer.net` is not Cloud (its host is
 * `api.e2b.app.customer.net`, which is not a child of `e2b.app`).
 */
export function isE2BCloudHostname(hostname: string): boolean {
  const host = normalizeHostname(hostname);
  return host === E2B_CLOUD_ROOT || host.endsWith(`.${E2B_CLOUD_ROOT}`);
}

function normalizeHostname(hostname: string): string {
  return hostname.trim().toLowerCase().replace(/\.+$/, '');
}

function parseHttpApiUrl(raw: string): URL {
  let parsed: URL;
  try {
    parsed = new URL(raw);
  } catch {
    throw new ConfigError(
      `Malformed ${ENV_API_URL}=${raw}. Must be an absolute http(s) URL ` +
        `(example: http://127.0.0.1:8080). Refusing to build.`,
      [ENV_API_URL],
    );
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw new ConfigError(
      `Malformed ${ENV_API_URL}=${raw}. Scheme must be http or https, got ${parsed.protocol}. ` +
        `Refusing to build.`,
      [ENV_API_URL],
    );
  }
  if (!parsed.hostname) {
    throw new ConfigError(
      `Malformed ${ENV_API_URL}=${raw}. URL has no hostname. Refusing to build.`,
      [ENV_API_URL],
    );
  }
  return parsed;
}

function hostnameFromDomainValue(raw: string): string {
  try {
    const parsed = raw.includes('://') ? new URL(raw) : new URL(`http://${raw}`);
    if (!parsed.hostname) {
      throw new Error('empty hostname');
    }
    return parsed.hostname;
  } catch {
    throw new ConfigError(
      `Malformed ${ENV_DOMAIN}=${raw}. Must be a hostname (example: e2b.example.com). Refusing to build.`,
      [ENV_DOMAIN],
    );
  }
}

function refuseCloud(envName: string, rawValue: string, hostname: string): void {
  const host = normalizeHostname(hostname);
  if (!isE2BCloudHostname(host)) {
    return;
  }
  throw new ConfigError(
    `${envName}=${rawValue} (hostname ${host}) targets E2B Cloud. ` +
      `Build refused because it would have targeted E2B Cloud. ` +
      `Set ${ENV_API_URL}=http://127.0.0.1:8080 for the local cluster.`,
    [envName],
  );
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

  const apiUrlRaw = env[ENV_API_URL]?.trim() || undefined;
  const domainRaw = env[ENV_DOMAIN]?.trim() || undefined;
  if (!apiUrlRaw && !domainRaw) {
    throw new ConfigError(
      `Missing ${ENV_API_URL} or ${ENV_DOMAIN}. ` +
        `Set ${ENV_API_URL}=http://127.0.0.1:8080 for local template builds. ` +
        `Refusing to default to e2b.app (E2B cloud).`,
      [ENV_API_URL, ENV_DOMAIN],
    );
  }

  let domainHostname: string | undefined;
  if (domainRaw) {
    domainHostname = hostnameFromDomainValue(domainRaw);
    refuseCloud(ENV_DOMAIN, domainRaw, domainHostname);
  }
  if (apiUrlRaw) {
    const parsed = parseHttpApiUrl(apiUrlRaw);
    refuseCloud(ENV_API_URL, apiUrlRaw, parsed.hostname);
  }

  // SDK ConnectionConfig: `opts.apiUrl || process.env.E2B_API_URL || https://api.${domain}`.
  // A truthy opts.apiUrl is required to stop a leftover process env from winning.
  const apiUrl = apiUrlRaw ?? `https://api.${domainHostname}`;

  return {
    apiKey,
    apiUrl,
    ...(domainRaw ? { domain: domainRaw } : {}),
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
    return { alias: spec.alias, templateId: null, action: 'skipped', buildId: null };
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

  return {
    alias: spec.alias,
    templateId: templateIdFromBuildInfo(info),
    action: 'built',
    buildId: info.buildId,
  };
}

function templateIdFromBuildInfo(info: { templateId?: unknown }): string | null {
  const value = info.templateId;
  return typeof value === 'string' && value.length > 0 ? value : null;
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
      results.push({ alias: spec.alias, templateId: null, action: 'failed', buildId: null });
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
