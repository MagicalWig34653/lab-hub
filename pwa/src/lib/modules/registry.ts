import { dmsManifest } from '#lib/modules-impl/dms/manifest';
import { registerMessages } from '#lib/i18n/index.svelte';
import type { ModuleManifest } from './manifest';

/** All built-in frontend modules. A backend module without an entry here is shown as "API/app only". */
export const registry: readonly ModuleManifest[] = [dmsManifest];

for (const manifest of registry) registerMessages(manifest.messages);
