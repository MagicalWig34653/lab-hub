import { describe, expect, it } from 'vitest';
import FileText from '@lucide/svelte/icons/file-text';
import type { ModuleManifest } from './manifest';
import { activeGroupId, buildSidebar, isItemActive, nextFocusIndex, openGroupIds, toggleChoice, type SidebarGroup, type SidebarItem } from './sidebar';

const icon = FileText;
const start: SidebarItem = { id: 'core.dashboard', path: '/dashboard', labelKey: 'nav.dashboard', icon, testId: 'nav-dashboard' };
const settings: SidebarGroup = { id: 'settings', labelKey: 'nav.settings', defaultOpen: false, items: [{ id: 's', path: '/settings/profile', labelKey: 'settings.profile', icon, testId: 't', exact: true }] };

const manifest: ModuleManifest = {
	key: 'm',
	routePrefix: '/m',
	icon,
	messages: { de: {}, en: {} },
	navigation: [
		{ id: 'work', labelKey: 'm.work', items: [{ id: 'a', path: '/m', labelKey: 'm.a', permission: 'm.read' }, { id: 'b', path: '/m/b', labelKey: 'm.b', permission: 'm.admin' }] },
		{ id: 'admin', labelKey: 'm.admin', defaultOpen: false, items: [{ id: 'c', path: '/m/c', labelKey: 'm.c', permission: 'm.admin' }] }
	]
};
const resolved = { items: [{ id: 'm.m', module: 'm', labelKey: 'nav.m', path: '/m', icon }], unavailable: [] };
const build = (can: (p: string) => boolean, items = resolved) => buildSidebar({ resolved: items, manifests: [manifest], can, core: { start, settings } });

describe('WP-F4c sidebar', () => {
	it('shows start, module groups with their permitted items, then settings', () => {
		const groups = build(() => true);
		expect(groups.map((g) => g.id)).toEqual(['start', 'm.work', 'm.admin', 'settings']);
		expect(groups[1].items.map((i) => i.path)).toEqual(['/m', '/m/b']);
	});

	it('hides items without permission and empty groups', () => {
		const groups = build((p) => p === 'm.read');
		expect(groups.map((g) => g.id)).toEqual(['start', 'm.work', 'settings']);
		expect(groups[1].items.map((i) => i.path)).toEqual(['/m']);
	});

	it('shows nothing of a module that is not effective (no resolved entry)', () => {
		expect(build(() => true, { items: [], unavailable: [] }).map((g) => g.id)).toEqual(['start', 'settings']);
	});

	it('a module without navigation groups falls back to its single backend entry', () => {
		const plain: ModuleManifest = { key: 'm', routePrefix: '/m', icon, messages: { de: {}, en: {} } };
		const groups = buildSidebar({ resolved, manifests: [plain], can: () => true, core: { start, settings } });
		expect(groups[1].items[0]).toMatchObject({ path: '/m', testId: 'nav-m' });
	});

	it('active item and group', () => {
		const groups = build(() => true);
		expect(activeGroupId(groups, '/m/c')).toBe('m.admin');
		expect(isItemActive({ path: '/m', matches: /^\/m(\/[0-9]+)?$/ }, '/m/12')).toBe(true);
		expect(isItemActive({ path: '/m', exact: true }, '/m/b')).toBe(false);
		expect(isItemActive({ path: '/m' }, '/m/b')).toBe(true);
	});

	it('open state: choice wins, the active group is always open, else the default', () => {
		const groups = build(() => true);
		expect([...openGroupIds(groups, new Map(), null)].sort()).toEqual(['m.work', 'start']);
		expect(openGroupIds(groups, new Map(), 'm.admin').has('m.admin')).toBe(true);
		expect(openGroupIds(groups, new Map([['m.work', false]]), null).has('m.work')).toBe(false);
		expect(openGroupIds(groups, new Map([['m.admin', true]]), null).has('m.admin')).toBe(true);
		// a group that appears later (module switched on) still follows its default
		expect(openGroupIds(groups, new Map([['settings', true]]), null).has('m.work')).toBe(true);
		expect(toggleChoice(new Map(), 'x', true).get('x')).toBe(false);
	});

	it('arrow keys move the focus, Home/End jump, nothing wraps', () => {
		expect(nextFocusIndex(3, -1, 'ArrowDown')).toBe(0);
		expect(nextFocusIndex(3, 2, 'ArrowDown')).toBe(2);
		expect(nextFocusIndex(3, 0, 'ArrowUp')).toBe(0);
		expect(nextFocusIndex(3, 1, 'End')).toBe(2);
		expect(nextFocusIndex(0, 0, 'Home')).toBe(-1);
	});
});
