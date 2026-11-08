import LayoutDashboard from '@lucide/svelte/icons/layout-dashboard';
import Monitor from '@lucide/svelte/icons/monitor';
import Puzzle from '@lucide/svelte/icons/puzzle';
import Shield from '@lucide/svelte/icons/shield';
import UserRound from '@lucide/svelte/icons/user-round';
import Users from '@lucide/svelte/icons/users';
import type { SidebarGroup, SidebarItem } from '#lib/modules/sidebar';

/** Core part of the sidebar: the start page and the settings group (WP-F4c). Modules add their own groups between them. */
export const coreStart: SidebarItem = { id: 'core.dashboard', path: '/dashboard', labelKey: 'nav.dashboard', icon: LayoutDashboard, testId: 'nav-dashboard' };

export function coreSettings(can: (permission: string) => boolean): SidebarGroup {
	const defs = [
		{ id: 'profile', labelKey: 'settings.profile', icon: UserRound },
		{ id: 'security', labelKey: 'settings.security', icon: Shield },
		{ id: 'sessions', labelKey: 'settings.sessions', icon: Monitor },
		{ id: 'modules', labelKey: 'settings.modules', icon: Puzzle, permission: 'tenant.module.manage' },
		{ id: 'members', labelKey: 'settings.members', icon: Users, permission: 'tenant.member.read' }
	] as const;
	return {
		id: 'settings',
		labelKey: 'nav.settings',
		defaultOpen: false,
		toggleTestId: 'nav-settings',
		items: defs
			.filter((d) => !('permission' in d) || can(d.permission))
			.map((d) => ({ id: `core.${d.id}`, path: `/settings/${d.id}`, labelKey: d.labelKey, icon: d.icon, testId: `settings-tab-${d.id}`, exact: true }))
	};
}
