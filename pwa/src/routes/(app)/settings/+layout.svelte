<script lang="ts">
	import { page } from '$app/state';
	import { t, type MessageKey } from '#lib/i18n/index.svelte';
	import { workspace } from '#lib/workspace.svelte';

	let { children } = $props();

	interface Tab {
		path: string;
		label: MessageKey;
		/** Tenant permission needed to see the tab (visibility only; the backend enforces it). */
		permission?: string;
	}

	const tabs: Tab[] = [
		{ path: '/settings/profile', label: 'settings.profile' },
		{ path: '/settings/security', label: 'settings.security' },
		{ path: '/settings/sessions', label: 'settings.sessions' },
		{ path: '/settings/modules', label: 'settings.modules', permission: 'tenant.module.manage' },
		{ path: '/settings/members', label: 'settings.members', permission: 'tenant.member.read' }
	];

	const visible = $derived(tabs.filter((tab) => !tab.permission || workspace.can(tab.permission)));
</script>

<h1 class="mb-4 text-2xl font-semibold">{t('settings.title')}</h1>
<nav aria-label={t('settings.title')} class="mb-6 border-b">
	<ul class="flex gap-1 overflow-x-auto">
		{#each visible as tab (tab.path)}
			<li>
				<a
					href={tab.path}
					aria-current={page.url.pathname === tab.path ? 'page' : undefined}
					class="hover:bg-muted aria-[current=page]:border-primary block border-b-2 border-transparent px-3 py-2 text-sm whitespace-nowrap aria-[current=page]:font-medium"
					data-testid={`settings-tab-${tab.path.split('/').pop()}`}
				>
					{t(tab.label)}
				</a>
			</li>
		{/each}
	</ul>
</nav>
{@render children()}
