<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { onMount, tick, untrack } from 'svelte';
	import ChevronDown from '@lucide/svelte/icons/chevron-down';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import Layers from '@lucide/svelte/icons/layers';
	import LogOut from '@lucide/svelte/icons/log-out';
	import MenuIcon from '@lucide/svelte/icons/menu';
	import Palette from '@lucide/svelte/icons/palette';
	import SettingsIcon from '@lucide/svelte/icons/settings';
	import XIcon from '@lucide/svelte/icons/x';
	import UserRound from '@lucide/svelte/icons/user-round';
	import LanguageSwitch from '#lib/components/app/LanguageSwitch.svelte';
	import * as Alert from '#lib/components/ui/alert';
	import { Button } from '#lib/components/ui/button';
	import { t, tx } from '#lib/i18n/index.svelte';
	import { coreSettings, coreStart } from '#lib/core-nav';
	import { registry } from '#lib/modules/registry';
	import { activeGroupId, activeItem, buildSidebar, nextFocusIndex, openGroupIds, toggleChoice, type SidebarItem } from '#lib/modules/sidebar';
	import { session } from '#lib/session.svelte';
	import { theme } from '#lib/theme/theme.svelte';
	import { workspace } from '#lib/workspace.svelte';

	let { children } = $props();

	// The session can vanish while the page is open (revoked on another device): leave quietly.
	$effect(() => {
		if (session.loaded && !session.current) {
			workspace.reset();
			theme.detach();
			void goto(`/login?next=${encodeURIComponent(page.url.pathname + page.url.search)}`);
		}
	});

	// The accent colour belongs to the account (WP-ST7): load it for the signed-in user.
	const userId = $derived(session.current && !session.isRecovery ? session.current.user.id : null);
	$effect(() => {
		const user = userId;
		if (user) untrack(() => void theme.attach(user));
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
		theme.detach();
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
	// Breadcrumbs in the header: group (if any) and the current page.
	const crumbGroup = $derived(groups.find((g) => g.id === activeId)?.labelKey ?? null);
	// A long sidebar scrolls the current entry into view (it can sit below the fold, e.g. in the settings group at the end).
	$effect(() => {
		void page.url.pathname;
		void groups;
		void open;
		void tick().then(() => navEl?.querySelector('[aria-current="page"]')?.scrollIntoView({ block: 'nearest' }));
	});
	function toggle(id: string) {
		choices = toggleChoice(choices, id, open.has(id));
		writeChoices(choices);
	}

	let drawer = $state(false);
	let mobile = $state(false);
	let navEl = $state<HTMLElement | null>(null);

	// The open drawer takes the focus and the page behind it is inert; closing it gives the focus back to the menu button.
	async function openDrawer() {
		drawer = true;
		await tick();
		document.querySelector<HTMLElement>('[data-testid="menu-close"]')?.focus();
	}
	async function closeDrawer() {
		drawer = false;
		await tick();
		document.querySelector<HTMLElement>('[data-testid="menu-toggle"]')?.focus();
	}

	onMount(() => {
		const media = window.matchMedia('(max-width: 1023px)');
		const update = () => {
			mobile = media.matches;
			if (!mobile) drawer = false;
		};
		update();
		media.addEventListener('change', update);
		const onKey = (event: KeyboardEvent) => {
			if (event.key === 'Escape' && drawer) void closeDrawer();
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
	<!-- Sidebar (WP-F4c, redesign WP-ST7): 256 px glass frame with grouped, collapsible sections; below lg a drawer. -->
	<aside
		id="app-sidebar"
		class="glass-sidebar fixed inset-y-0 left-0 z-40 flex w-64 flex-col border-r transition-transform motion-reduce:transition-none max-lg:shadow-xl {drawer ? 'translate-x-0' : 'max-lg:invisible max-lg:-translate-x-full'}"
		inert={mobile && !drawer}
		data-testid="sidebar"
	>
		<div class="mx-3 flex h-[60px] shrink-0 items-center gap-2">
			<a href="/dashboard" class="flex min-w-0 flex-1 items-center gap-2.5 self-stretch rounded-lg px-2 text-[17px] font-semibold tracking-tight">
				<span class="bg-background text-ui-accent-ink flex size-[34px] items-center justify-center rounded-lg border" aria-hidden="true">
					<Layers class="size-[18px]" />
				</span>
				{t('app.name')}
			</a>
			<Button variant="ghost" size="icon" class="lg:hidden" aria-label={t('shell.closeMenu')} onclick={closeDrawer} data-testid="menu-close">
				<XIcon class="size-[18px]" aria-hidden="true" />
			</Button>
		</div>
		<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
		<nav aria-label={t('shell.navigation')} class="flex min-h-0 flex-1 flex-col overflow-y-auto px-3 pb-3" bind:this={navEl} onkeydown={navKeydown}>
			{#each groups as group (group.id)}
				{#if group.labelKey}
					{@const isOpen = open.has(group.id)}
					<div class="mt-3 shrink-0 first:mt-0 {group.id === 'settings' ? 'mt-auto border-t pt-2' : ''}">
						<button
							type="button"
							data-nav-item
							class="text-muted-foreground hover:text-foreground flex w-full items-center justify-between rounded-md px-3 py-1.5 text-left text-[11px] font-semibold tracking-[0.06em] uppercase max-lg:min-h-10"
							aria-expanded={isOpen}
							aria-controls={`nav-group-${group.id}`}
							onclick={() => toggle(group.id)}
							data-testid={group.toggleTestId ?? `nav-group-${group.id}`}
						>
							<span>{tx(group.labelKey)}</span>
							<ChevronDown class="size-3.5 transition-transform motion-reduce:transition-none {isOpen ? 'rotate-180' : ''}" aria-hidden="true" />
						</button>
						<ul id={`nav-group-${group.id}`} class="mt-0.5 space-y-0.5" hidden={!isOpen}>
							{#each group.items as item (item.id)}
								{@render link(item, isOpen)}
							{/each}
						</ul>
					</div>
				{:else}
					<ul class="mb-1 shrink-0 space-y-0.5">
						{#each group.items as item (item.id)}
							{@render link(item, true)}
						{/each}
					</ul>
				{/if}
			{/each}
		</nav>
		<div class="grid shrink-0 gap-2 border-t p-3 lg:hidden">
			<Button variant="outline" href="/settings/profile" data-testid="drawer-settings"><SettingsIcon class="size-4" aria-hidden="true" />{t('nav.settings')}</Button>
			<Button variant="outline" onclick={logout} data-testid="drawer-logout"><LogOut class="size-4" aria-hidden="true" />{t('shell.logout')}</Button>
		</div>
	</aside>
	{#if drawer}
		<button type="button" class="fixed inset-0 z-30 bg-black/30 backdrop-blur-[2px] lg:hidden" aria-label={t('shell.closeMenu')} tabindex="-1" onclick={closeDrawer}></button>
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
			class="flex min-h-[38px] items-center gap-3 rounded-lg px-3 py-1.5 text-sm font-medium max-lg:min-h-11 {active ? 'bg-ui-accent-soft text-ui-accent-ink font-semibold' : 'text-muted-foreground hover:bg-muted hover:text-foreground'}"
			aria-current={active ? 'page' : undefined}
			data-testid={item.testId}
		>
			<Icon class="size-[18px] shrink-0" aria-hidden="true" />
			<span class="min-w-0 break-words">{tx(item.labelKey)}</span>
		</a>
	</li>
{/snippet}

<div class={session.isRecovery ? '' : 'lg:pl-64'} inert={mobile && drawer} data-testid="shell-content">
	<header class="glass-header sticky top-0 z-20 border-b">
		<div class="flex min-h-[60px] items-center justify-between gap-2 px-4 py-2 sm:gap-3 min-[1101px]:px-10">
			<div class="flex min-w-0 flex-auto items-center gap-2">
				{#if !session.isRecovery}
					<Button variant="ghost" size="icon" class="lg:hidden" aria-label={t('shell.openMenu')} aria-expanded={drawer} aria-controls="app-sidebar" onclick={openDrawer} data-testid="menu-toggle">
						<MenuIcon class="size-[18px]" aria-hidden="true" />
					</Button>
				{/if}
				{#if session.isRecovery}
					<a href="/dashboard" class="truncate font-semibold">{t('app.name')}</a>
				{:else}
					<p class="truncate font-semibold lg:hidden" data-testid="header-title">{currentItem ? tx(currentItem.labelKey) : t('app.name')}</p>
				{/if}
				{#if currentItem && !session.isRecovery}
					<p class="flex min-w-0 items-center gap-1.5 text-sm max-lg:hidden" data-testid="breadcrumbs">
						{#if crumbGroup}
							<span class="text-muted-foreground truncate">{tx(crumbGroup)}</span>
							<ChevronRight class="text-muted-foreground size-3.5 shrink-0" aria-hidden="true" />
						{/if}
						<span class="truncate font-semibold">{tx(currentItem.labelKey)}</span>
					</p>
				{/if}
			</div>
			<div class="flex min-w-0 flex-initial items-center justify-end gap-1 sm:gap-3">
				{#if workspace.memberships.length > 1 && !session.isRecovery}
					<label class="text-muted-foreground flex min-w-0 items-center gap-2 text-sm">
						<span class="sr-only">{t('shell.tenant')}</span>
						<select
							class="hover:bg-muted bg-background text-foreground h-9 w-37 max-w-full min-w-0 truncate sm:w-auto rounded-lg border border-transparent px-1 text-sm font-medium sm:max-w-56"
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
					<span class="text-muted-foreground max-w-40 truncate text-sm max-sm:hidden" data-testid="tenant-name">{workspace.detail.name}</span>
				{/if}
				<div class="max-sm:hidden"><LanguageSwitch compact /></div>
				{#if !session.isRecovery}
					<Button
						variant="ghost"
						size="icon"
						class="max-sm:hidden"
						href="/settings/appearance"
						aria-label={t('settings.appearance')}
						title={t('settings.appearance')}
						data-testid="header-appearance"
					>
						<Palette class="size-[18px]" aria-hidden="true" />
					</Button>
					<a
						href="/settings/profile"
						class="text-muted-foreground hover:bg-muted hover:text-foreground flex h-10 min-w-10 items-center justify-center gap-2 rounded-lg px-2 text-sm"
					>
						<UserRound class="size-[18px] shrink-0" aria-hidden="true" />
						<span class="max-w-40 truncate max-md:sr-only" data-testid="user-name">{session.current?.user.display_name}</span>
					</a>
				{:else}
					<span class="text-muted-foreground text-sm" data-testid="user-name">{session.current?.user.display_name}</span>
				{/if}
				<Button variant="ghost" size="icon" class="max-lg:hidden" aria-label={t('shell.logout')} title={t('shell.logout')} onclick={logout} data-testid="logout">
					<LogOut class="size-[18px]" aria-hidden="true" />
				</Button>
				{#if session.isRecovery}
					<Button variant="outline" size="sm" class="lg:hidden" onclick={logout}>{t('shell.logout')}</Button>
				{/if}
			</div>
		</div>
	</header>
	<main id="main" class="mx-auto w-full max-w-[1240px] min-w-0 px-4 py-[22px] min-[761px]:px-6 min-[761px]:py-7 min-[1101px]:px-10 min-[1101px]:py-9">
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