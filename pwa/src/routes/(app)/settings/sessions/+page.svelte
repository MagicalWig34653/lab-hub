<script lang="ts">
	import { goto } from '$app/navigation';
	import { onMount } from 'svelte';
	import { authApi, type SessionInfo } from '#lib/api/client';
	import ErrorBanner from '#lib/components/app/ErrorBanner.svelte';
	import { Button } from '#lib/components/ui/button';
	import * as Card from '#lib/components/ui/card';
	import { formatDateTime } from '#lib/format';
	import { errorMessage, i18n, t } from '#lib/i18n/index.svelte';
	import { session } from '#lib/session.svelte';
	import { workspace } from '#lib/workspace.svelte';

	let sessions = $state<SessionInfo[]>([]);
	let error = $state<string | null>(null);
	let confirmAll = $state(false);

	async function load() {
		try {
			sessions = (await authApi.sessions()).items;
		} catch (e) {
			error = errorMessage(e);
		}
	}
	onMount(() => void load());

	async function revoke(id: string) {
		error = null;
		try {
			await authApi.revokeSession(id);
			await load();
		} catch (e) {
			error = errorMessage(e);
		}
	}

	async function logoutAll() {
		if (!confirmAll) {
			confirmAll = true;
			return;
		}
		error = null;
		try {
			await session.logoutAll();
			workspace.reset();
			await goto('/login');
		} catch (e) {
			error = errorMessage(e);
			confirmAll = false;
		}
	}
</script>

<svelte:head><title>{t('settings.sessions')} · {t('app.name')}</title></svelte:head>

<Card.Root>
	<Card.Header>
		<Card.Title><h2 class="text-lg font-semibold">{t('sessions.title')}</h2></Card.Title>
		<Card.Description>{t('sessions.description')}</Card.Description>
	</Card.Header>
	<Card.Content class="space-y-4">
		<ErrorBanner message={error} />
		<ul class="divide-y" data-testid="session-list">
			{#each sessions as item (item.id)}
				<li class="flex flex-wrap items-center justify-between gap-2 py-2" data-current={item.current}>
					<div>
						<div class="font-medium">
							{item.current ? t('sessions.current') : t('sessions.other')}
							{#if item.kind === 'recovery'}<span class="text-muted-foreground text-xs">({t('sessions.recovery')})</span>{/if}
						</div>
						<div class="text-muted-foreground text-xs">
							{t('sessions.since', { date: formatDateTime(item.created_at, i18n.locale) })}
							·
							{t('sessions.lastSeen', { date: formatDateTime(item.last_seen_at, i18n.locale) })}
						</div>
					</div>
					{#if !item.current}
						<Button variant="outline" size="sm" onclick={() => revoke(item.id)} data-testid="session-revoke">
							{t('sessions.revoke')}
						</Button>
					{/if}
				</li>
			{/each}
		</ul>
		<div class="flex flex-wrap items-center gap-2">
			<Button variant="destructive" onclick={logoutAll} data-testid="logout-all">
				{confirmAll ? t('sessions.logoutAllConfirm') : t('sessions.logoutAll')}
			</Button>
			{#if confirmAll}
				<Button variant="outline" onclick={() => (confirmAll = false)}>{t('common.cancel')}</Button>
			{/if}
		</div>
	</Card.Content>
</Card.Root>
