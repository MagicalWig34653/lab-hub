import type { Component } from 'svelte';
import type { NavigationEntry, TenantModuleItem } from '#lib/api/client';
import type { IconProps, ModuleManifest } from './manifest';

export interface NavItem {
	id: string;
	module: string;
	labelKey: string;
	path: string;
	icon: Component<IconProps>;
}

export interface ResolvedNavigation {
	items: NavItem[];
	/** Effective backend modules without a frontend manifest ("only via API/app"). */
	unavailable: string[];
}

/** True when `path` is the prefix itself or lies below it (`/dms`, `/dms/x`, but not `/dmsx`). */
export function isUnderPrefix(path: string, prefix: string): boolean {
	return path === prefix || path.startsWith(prefix + '/');
}

/**
 * Navigation = intersection of the backend navigation (already filtered by role permission), the effective modules and the
 * frontend manifests (AK-F2-1). Entries pointing outside the manifest's route prefix are dropped.
 */
export function resolveNavigation(
	navigation: readonly NavigationEntry[],
	modules: readonly TenantModuleItem[],
	manifests: readonly ModuleManifest[]
): ResolvedNavigation {
	const effective = new Set(modules.filter((m) => m.effective).map((m) => m.key));
	const byKey = new Map(manifests.map((m) => [m.key, m]));
	const items: NavItem[] = [];
	for (const entry of navigation) {
		const manifest = byKey.get(entry.module);
		if (!manifest || !effective.has(entry.module) || !isUnderPrefix(entry.path, manifest.routePrefix)) continue;
		items.push({ id: `${entry.module}.${entry.key}`, module: entry.module, labelKey: entry.label_key, path: entry.path, icon: manifest.icon });
	}
	const unavailable = [...effective].filter((key) => !byKey.has(key)).sort();
	return { items, unavailable };
}

/** A module route is usable only while its module is effective in the active tenant (else `ModuleDisabled`). */
export function isModuleEffective(modules: readonly TenantModuleItem[], key: string): boolean {
	return modules.some((m) => m.key === key && m.effective);
}
