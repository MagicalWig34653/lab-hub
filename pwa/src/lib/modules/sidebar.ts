import type { Component } from 'svelte';
import type { ResolvedNavigation } from './resolve';
import { isUnderPrefix } from './resolve';
import type { IconProps, ModuleManifest, NavGroupDef } from './manifest';

/** One link of the sidebar, already filtered by permission and module activation. */
export interface SidebarItem {
	id: string;
	path: string;
	labelKey: string;
	icon: Component<IconProps>;
	testId: string;
	/** Current-page test; default is "path or below". */
	matches?: RegExp;
	exact?: boolean;
}

/** A section of the sidebar. Without `labelKey` it is a heading-less block (the start page). Collapsible groups remember their state. */
export interface SidebarGroup {
	id: string;
	labelKey: string | null;
	items: SidebarItem[];
	defaultOpen: boolean;
	/** Core group whose toggle button carries a fixed test id (e.g. settings). */
	toggleTestId?: string;
}

export function isItemActive(item: Pick<SidebarItem, 'path' | 'matches' | 'exact'>, pathname: string): boolean {
	if (item.matches) return item.matches.test(pathname);
	return item.exact ? pathname === item.path : isUnderPrefix(pathname, item.path);
}

/** The current item: among all matching items the one with the longest path wins (`/dms` must not stay current on `/dms/rules`). */
export function activeItem(groups: readonly SidebarGroup[], pathname: string): SidebarItem | null {
	let best: SidebarItem | null = null;
	for (const g of groups) for (const i of g.items) if (isItemActive(i, pathname) && (!best || i.path.length > best.path.length)) best = i;
	return best;
}

/** The group containing the current item, if any. */
export function activeGroupId(groups: readonly SidebarGroup[], pathname: string): string | null {
	const item = activeItem(groups, pathname);
	return item ? (groups.find((g) => g.items.includes(item))?.id ?? null) : null;
}

/**
 * Sidebar = start page, then the groups of every module that is effective in the tenant and has a frontend manifest
 * (module navigation of the F2 mechanism: the backend navigation decides which modules appear, the manifest delivers the
 * groups), then the settings group of the core. Items need their permission (visibility only; the backend authorizes).
 * A module without `navigation` groups falls back to the single backend entry.
 */
export function buildSidebar(opts: {
	resolved: ResolvedNavigation;
	manifests: readonly ModuleManifest[];
	can: (permission: string) => boolean;
	core: { start: SidebarItem; settings: SidebarGroup };
}): SidebarGroup[] {
	const { resolved, manifests, can, core } = opts;
	const groups: SidebarGroup[] = [{ id: 'start', labelKey: null, items: [core.start], defaultOpen: true }];
	const byKey = new Map(manifests.map((m) => [m.key, m]));
	const seen = new Set<string>();
	for (const entry of resolved.items) {
		if (seen.has(entry.module)) continue;
		seen.add(entry.module);
		const manifest = byKey.get(entry.module);
		const defs: NavGroupDef[] | undefined = manifest?.navigation;
		if (!manifest || !defs) {
			groups.push({
				id: `${entry.module}`,
				labelKey: null,
				defaultOpen: true,
				items: [{ id: entry.id, path: entry.path, labelKey: entry.labelKey, icon: entry.icon, testId: `nav-${entry.module}` }]
			});
			continue;
		}
		for (const def of defs) {
			const items = def.items
				.filter((i) => isUnderPrefix(i.path, manifest.routePrefix) && (!i.permission || can(i.permission)))
				.map((i): SidebarItem => ({ id: `${manifest.key}.${i.id}`, path: i.path, labelKey: i.labelKey, icon: i.icon ?? manifest.icon, testId: i.testId ?? `${manifest.key}-nav-${i.id}`, matches: i.matches, exact: i.exact }));
			if (items.length > 0) groups.push({ id: `${manifest.key}.${def.id}`, labelKey: def.labelKey, items, defaultOpen: def.defaultOpen ?? true });
		}
	}
	const settingsItems = core.settings.items;
	if (settingsItems.length > 0) groups.push(core.settings);
	return groups;
}

/** Open state: an explicit choice of the user wins, else the group of the current page is open, else the group's default. */
export function openGroupIds(groups: readonly SidebarGroup[], choices: ReadonlyMap<string, boolean>, activeId: string | null): Set<string> {
	const open = new Set<string>();
	for (const g of groups) {
		const choice = choices.get(g.id);
		if (choice === true || (choice === undefined && (g.defaultOpen || g.id === activeId))) open.add(g.id);
		if (choice === false && g.id === activeId) open.add(g.id);
	}
	return open;
}

export function toggleChoice(choices: ReadonlyMap<string, boolean>, id: string, currentlyOpen: boolean): Map<string, boolean> {
	const next = new Map(choices);
	next.set(id, !currentlyOpen);
	return next;
}

/** Index of the next focus target for arrow keys in the sidebar (wraps nowhere; Home/End jump). */
export function nextFocusIndex(count: number, current: number, key: string): number {
	if (count === 0) return -1;
	if (key === 'Home') return 0;
	if (key === 'End') return count - 1;
	if (current < 0) return key === 'ArrowUp' ? count - 1 : 0;
	return Math.max(0, Math.min(count - 1, current + (key === 'ArrowDown' ? 1 : -1)));
}
