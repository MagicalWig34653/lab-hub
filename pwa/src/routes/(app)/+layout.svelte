<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { onMount } from 'svelte';
	import LayoutDashboard from '@lucide/svelte/icons/layout-dashboard';
	import SettingsIcon from '@lucide/svelte/icons/settings';
	import LanguageSwitch from '#lib/components/app/LanguageSwitch.svelte';
	import * as Alert from '#lib/components/ui/alert';
	import { Button } from '#lib/components/ui/button';
	import { t, tx } from '#lib/i18n/index.svelte';
	import { isUnderPrefix } from '#lib/modules/resolve';
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

	const current = (path: string) => (isUnderPrefix(page.url.pathname, path) ? 'page' : undefined);
	const linkClass =
		'hover:bg-muted aria-[current=page]:bg-muted aria-[current=page]:font-medium flex items-center gap-2 rounded-md px-3 py-2 text-sm whitespace-nowrap';
</script>

<a
	href="#main"
	class="bg-background focus:border-ring sr-only rounded-md p-2 focus:not-sr-only focus:absolute focus:top-2 focus:left-2 focus:border"
>
	{t('shell.skipToContent')}
</a>
<header class="border-b">
	<div class="flex flex-wrap items-center justify-between gap-3 p-3">
		<a href="/dashboard" class="font-semibold">{t('app.name')}</a>
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
			<Button variant="outline" size="sm" onclick={logout} data-testid="logout">{t('shell.logout')}</Button>
		</div>
	</div>
</header>
<div class="md:flex">
	{#if !session.isRecovery}
		<nav aria-label={t('shell.navigation')} class="border-b md:min-h-[calc(100vh-3.5rem)] md:w-56 md:shrink-0 md:border-r md:border-b-0" data-testid="sidebar">
			<ul class="flex gap-1 overflow-x-auto p-2 md:flex-col">
				<li>
					<a href="/dashboard" class={linkClass} aria-current={current('/dashboard')}>
						<LayoutDashboard class="size-4" aria-hidden="true" />{t('nav.dashboard')}
					</a>
				</li>
				{#each workspace.navigation.items as item (item.id)}
					{@const Icon = item.icon}
					<li>
						<a href={item.path} class={linkClass} aria-current={current(item.path)} data-testid={`nav-${item.module}`}>
							<Icon class="size-4" aria-hidden="true" />{tx(item.labelKey)}
						</a>
					</li>
				{/each}
				<li>
					<a href="/settings" class={linkClass} aria-current={current('/settings')} data-testid="nav-settings">
						<SettingsIcon class="size-4" aria-hidden="true" />{t('nav.settings')}
					</a>
				</li>
			</ul>
		</nav>
	{/if}
	<main id="main" class="mx-auto w-full max-w-5xl min-w-0 p-4">
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
