import { Template } from 'e2b';

export const DEFAULT_BASE_IMAGE = 'e2bdev/base';

export const BASE_IMAGE_ENV = 'E2B_BASE_IMAGE';

export interface TemplateSpec {
  alias: string;
  cpuCount: number;
  memoryMB: number;
  aptPackages: readonly string[];
}

export const TEMPLATE_SPECS: readonly TemplateSpec[] = [
  { alias: 'base', cpuCount: 2, memoryMB: 512, aptPackages: [] },
  { alias: 'kodus-sandbox', cpuCount: 2, memoryMB: 1024, aptPackages: ['git', 'ripgrep'] },
  { alias: 'kodus-sandbox-graph', cpuCount: 2, memoryMB: 2560, aptPackages: ['git', 'ripgrep'] },
];

export const TEMPLATE_ALIASES: readonly string[] = TEMPLATE_SPECS.map((spec) => spec.alias);

export function resolveBaseImage(env: NodeJS.ProcessEnv = process.env): string {
  const raw = env[BASE_IMAGE_ENV];
  if (raw !== undefined && raw.trim() !== '') {
    return raw.trim();
  }
  return DEFAULT_BASE_IMAGE;
}

export function createTemplate(spec: TemplateSpec, baseImage: string = DEFAULT_BASE_IMAGE) {
  const started = Template();
  const withImage =
    baseImage === DEFAULT_BASE_IMAGE ? started.fromBaseImage() : started.fromImage(baseImage);
  if (spec.aptPackages.length > 0) {
    return withImage.aptInstall([...spec.aptPackages]);
  }
  return withImage;
}
