import { registry } from './registry';
import { isUnderPrefix } from './resolve';
import type { ModuleManifest } from './manifest';

/** First path segments owned by the core (not by a module). Everything else must live below exactly one module prefix. */
export const CORE_SEGMENTS = ['', 'dashboard', 'settings', 'login', 'setup', 'invite', 'recover'] as const;

export type RouteClass = { kind: 'core' } | { kind: 'module'; module: string } | { kind: 'unclassified'; modules?: string[] };

/** Classifies a SvelteKit route like `(app)/dms/[id]` (group folders are ignored). */
export function classifyRoute(route: string, manifests: readonly ModuleManifest[] = registry): RouteClass {
	const path = '/' + route.split('/').filter((s) => s && !(s.startsWith('(') && s.endsWith(')'))).join('/');
	const owners = manifests.filter((m) => isUnderPrefix(path, m.routePrefix)).map((m) => m.key);
	if (owners.length > 1) return { kind: 'unclassified', modules: owners };
	if (owners.length === 1) return { kind: 'module', module: owners[0] };
	const first = path.split('/')[1] ?? '';
	return (CORE_SEGMENTS as readonly string[]).includes(first) ? { kind: 'core' } : { kind: 'unclassified' };
}
