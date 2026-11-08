<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { onMount, untrack } from 'svelte';
	import ChevronDown from '@lucide/svelte/icons/chevron-down';
	import MenuIcon from '@lucide/svelte/icons/menu';
	import LanguageSwitch from '#lib/components/app/LanguageSwitch.svelte';
	import * as Alert from '#lib/components/ui/alert';
	import { Button } from '#lib/components/ui/button';
	import { t, tx } from '#lib/i18n/index.svelte';
	import { coreSettings, coreStart } from '#lib/core-nav';
	import { registry } from '#lib/modules/registry';
	import { activeGroupId, activeItem, buildSidebar, nextFocusIndex, openGroupIds, toggleChoice, type SidebarItem } from '#lib/modules/sidebar';
	import { session } from '#lib/session.svelte';
	import { workspace } from '#lib/workspace.svelte';

	let { children } = $props();

	// The session can vanish while the page is open (revoked on another device): leave quietly.
	$effect(() => {
		if (session.loaded && !session.current) {
			workspace.reset();
			void goto(`/login?next=${encodeURIComponent(page.url.pathname + page.url.search)}`);
		}
	});

	// Module changes made elsewhere apply when the tab becomes visible again (AK-F2-2, no rebuild).
	onMount(() => {
		const onVisible = () => {
			if (document.visibilityState === 'visible') void workspace.refreshModules();
		};
		document.addEventListener('visibilitychange', onVisible);
		return () => document.removeEventListener('visibilitychange', onVisible);
	});

	async function logout() {
		await session.logout();
		workspace.reset();
		await goto('/login');
	}

	function onTenantChange(event: Event) {
		void workspace.switchTo((event.currentTarget as HTMLSelectElement).value);
	}

	// --- sidebar: groups from the core and the module manifests (permission dependent), open state remembered per browser ---
	const groups = $derived(
		buildSidebar({
			resolved: workspace.navigation,
			manifests: registry,
			can: (permission) => workspace.can(permission),
			core: { start: coreStart, settings: coreSettings((permission) => workspace.can(permission)) }
		})
	);
	const OPEN_KEY = 'lh.nav.open';
	function readChoices(): Map<string, boolean> {
		try {
			const raw = localStorage.getItem(OPEN_KEY);
			return new Map(Object.entries(raw ? (JSON.parse(raw) as Record<string, boolean>) : {}));
		} catch {
			return new Map();
		}
	}
	function writeChoices(value: Map<string, boolean>) {
		try {
			localStorage.setItem(OPEN_KEY, JSON.stringify(Object.fromEntries(value)));
		} catch {
			// the open state is only a convenience
		}
	}
	let choices = $state<Map<string, boolean>>(new Map());
	onMount(() => (choices = readChoices()));
	const activeId = $derived(activeGroupId(groups, page.url.pathname));
	const currentItem = $derived(activeItem(groups, page.url.pathname));
	const open = $derived(openGroupIds(groups, choices, activeId));
	function toggle(id: string) {
		choices = toggleChoice(choices, id, open.has(id));
		writeChoices(choices);
	}

	let drawer = $state(false);
	let mobile = $state(false);
	let navEl = $state<HTMLElement | null>(null);

	onMount(() => {
		const media = window.matchMedia('(max-width: 1023px)');
		const update = () => {
			mobile = media.matches;
			if (!mobile) drawer = false;
		};
		update();
		media.addEventListener('change', update);
		const onKey = (event: KeyboardEvent) => {
			if (event.key === 'Escape' && drawer) drawer = false;
		};
		window.addEventListener('keydown', onKey);
		return () => {
			media.removeEventListener('change', update);
			window.removeEventListener('keydown', onKey);
		};
	});

	// A navigation closes the drawer.
	$effect(() => {
		void page.url.pathname;
		untrack(() => (drawer = false));
	});

	function navKeydown(event: KeyboardEvent) {
		if (!['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(event.key) || !navEl) return;
		const items = [...navEl.querySelectorAll<HTMLElement>('[data-nav-item]')];
		const index = nextFocusIndex(items.length, items.indexOf(document.activeElement as HTMLElement), event.key);
		if (index < 0) return;
		event.preventDefault();
		items[index].focus();
	}
</script>

<a
	href="#main"
	class="bg-background focus:border-ring sr-only rounded-md p-2 focus:not-sr-only focus:absolute focus:top-2 focus:left-2 focus:border"
>
	{t('shell.skipToContent')}
</a>

{#if !session.isRecovery}
	<!-- Sidebar (WP-F4c): grouped, collapsible sections; below lg it is a drawer opened from the top bar. -->
	<aside
		id="app-sidebar"
		class="bg-muted/40 fixed inset-y-0 left-0 z-40 flex w-64 flex-col border-r px-3 py-4 transition-transform motion-reduce:transition-none max-lg:bg-background {drawer ? 'translate-x-0' : 'max-lg:invisible max-lg:-translate-x-full'}"
		inert={mobile && !drawer}
		data-testid="sidebar"
	>
		<a href="/dashboard" class="mb-3 flex items-center gap-2 rounded-lg px-2 py-2 text-[15px] font-semibold tracking-tight">{t('app.name')}</a>
		<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
		<nav aria-label={t('shell.navigation')} class="min-h-0 flex-1 overflow-y-auto" bind:this={navEl} onkeydown={navKeydown}>
			{#each groups as group (group.id)}
				{#if group.labelKey}
					{@const isOpen = open.has(group.id)}
					<div class="mt-4 first:mt-0">
						<button
							type="button"
							data-nav-item
							class="text-muted-foreground hover:text-foreground focus-visible:ring-ring/50 flex w-full items-center justify-between rounded-md px-2.5 py-1.5 text-left text-xs font-medium tracking-wide uppercase focus-visible:ring-3 focus-visible:outline-none"
							aria-expanded={isOpen}
							aria-controls={`nav-group-${group.id}`}
							onclick={() => toggle(group.id)}
							data-testid={group.toggleTestId ?? `nav-group-${group.id}`}
						>
							<span>{tx(group.labelKey)}</span>
							<ChevronDown class="size-4 transition-transform motion-reduce:transition-none {isOpen ? 'rotate-180' : ''}" aria-hidden="true" />
						</button>
						<ul id={`nav-group-${group.id}`} class="mt-1 space-y-0.5" hidden={!isOpen}>
							{#each group.items as item (item.id)}
								{@render link(item, isOpen)}
							{/each}
						</ul>
					</div>
				{:else}
					<ul class="mb-1 space-y-0.5">
						{#each group.items as item (item.id)}
							{@render link(item, true)}
						{/each}
					</ul>
				{/if}
			{/each}
		</nav>
		<div class="mt-3 border-t pt-3 lg:hidden">
			<Button variant="outline" size="sm" class="w-full" onclick={logout}>{t('shell.logout')}</Button>
		</div>
	</aside>
	{#if drawer}
		<button type="button" class="fixed inset-0 z-30 bg-black/40 lg:hidden" aria-label={t('shell.closeMenu')} onclick={() => (drawer = false)}></button>
	{/if}
{/if}

{#snippet link(item: SidebarItem, tabbable: boolean)}
	{@const Icon = item.icon}
	{@const active = currentItem === item}
	<li>
		<a
			href={item.path}
			data-nav-item={tabbable ? '' : undefined}
			tabindex={tabbable ? undefined : -1}
			class="hover:bg-muted focus-visible:ring-ring/50 flex min-h-9 items-center gap-2.5 rounded-md px-2.5 py-1.5 text-sm focus-visible:ring-3 focus-visible:outline-none {active ? 'bg-secondary font-medium' : ''}"
			aria-current={active ? 'page' : undefined}
			data-testid={item.testId}
		>
			<Icon class="text-muted-foreground size-4 shrink-0" aria-hidden="true" />
			<span class="min-w-0 break-words">{tx(item.labelKey)}</span>
		</a>
	</li>
{/snippet}

<div class={session.isRecovery ? '' : 'lg:pl-64'}>
	<header class="bg-background/95 sticky top-0 z-20 border-b backdrop-blur">
		<div class="flex flex-wrap items-center justify-between gap-3 p-3">
			<div class="flex items-center gap-2">
				{#if !session.isRecovery}
					<Button variant="outline" size="icon-sm" class="lg:hidden" aria-label={t('shell.openMenu')} aria-expanded={drawer} aria-controls="app-sidebar" onclick={() => (drawer = true)} data-testid="menu-toggle">
						<MenuIcon class="size-4" aria-hidden="true" />
					</Button>
				{/if}
				<a href="/dashboard" class="font-semibold {session.isRecovery ? '' : 'lg:hidden'}">{t('app.name')}</a>
			</div>
			<div class="flex flex-wrap items-center gap-3">
				{#if workspace.memberships.length > 1 && !session.isRecovery}
					<label class="text-muted-foreground flex items-center gap-2 text-sm">
						<span>{t('shell.tenant')}</span>
						<select
							class="border-input bg-background h-8 rounded-md border px-2 text-sm"
							value={workspace.activeId ?? ''}
							onchange={onTenantChange}
							data-testid="tenant-switch"
						>
							{#each workspace.memberships as membership (membership.tenant_id)}
								<option value={membership.tenant_id}>{membership.name}</option>
							{/each}
						</select>
					</label>
				{:else if workspace.detail}
					<span class="text-muted-foreground text-sm" data-testid="tenant-name">{workspace.detail.name}</span>
				{/if}
				<LanguageSwitch />
				<span class="text-muted-foreground text-sm" data-testid="user-name">{session.current?.user.display_name}</span>
				<Button variant="outline" size="sm" class="max-lg:hidden" onclick={logout} data-testid="logout">{t('shell.logout')}</Button>
			</div>
		</div>
	</header>
	<main id="main" class="mx-auto w-full max-w-6xl min-w-0 p-4 md:p-6">
		{#if workspace.error}
			<div role="alert" class="mb-4">
				<Alert.Root variant="destructive">
					<Alert.Description>
						<p>{workspace.error}</p>
						<Button class="mt-2" variant="outline" size="sm" onclick={() => workspace.reload()}>{t('common.retry')}</Button>
					</Alert.Description>
				</Alert.Root>
			</div>
		{/if}
		<!-- Re-keyed on tenant change: module pages start fresh and no data of the previous tenant stays mounted. -->
		{#key workspace.activeId}
			{@render children()}
		{/key}
	</main>
</div>