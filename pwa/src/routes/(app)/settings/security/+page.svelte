<script lang="ts">
	import { onMount } from 'svelte';
	import { meApi, type PasskeyInfo } from '#lib/api/client';
	import ErrorBanner from '#lib/components/app/ErrorBanner.svelte';
	import RecoveryCodes from '#lib/components/app/RecoveryCodes.svelte';
	import { Button } from '#lib/components/ui/button';
	import * as Card from '#lib/components/ui/card';
	import { Input } from '#lib/components/ui/input';
	import { Label } from '#lib/components/ui/label';
	import { formatDateTime } from '#lib/format';
	import { errorMessage, i18n, t } from '#lib/i18n/index.svelte';
	import { session } from '#lib/session.svelte';

	let passkeys = $state<PasskeyInfo[]>([]);
	let name = $state('');
	let pending = $state(false);
	let error = $state<string | null>(null);

	async function load() {
		try {
			passkeys = (await meApi.passkeys()).items;
		} catch (e) {
			error = errorMessage(e);
		}
	}
	onMount(() => void load());

	async function add(event: SubmitEvent) {
		event.preventDefault();
		pending = true;
		error = null;
		try {
			await session.addPasskey(name.trim() || t('passkeys.defaultName'));
			name = '';
			await load();
		} catch (e) {
			error = errorMessage(e);
		} finally {
			pending = false;
		}
	}

	async function remove(id: string) {
		error = null;
		try {
			await meApi.revokePasskey(id);
			await load();
		} catch (e) {
			error = errorMessage(e);
		}
	}
</script>

<svelte:head><title>{t('settings.security')} · {t('app.name')}</title></svelte:head>

<div class="space-y-6">
	<Card.Root>
		<Card.Header><Card.Title><h2 class="text-lg font-semibold">{t('passkeys.title')}</h2></Card.Title></Card.Header>
		<Card.Content class="space-y-4">
			<ErrorBanner message={error} />
			<ul class="divide-y" data-testid="passkey-list">
				{#each passkeys as passkey (passkey.id)}
					<li class="flex flex-wrap items-center justify-between gap-2 py-2">
						<div>
							<div class="font-medium">{passkey.name}</div>
							<div class="text-muted-foreground text-xs">
								{t('passkeys.created', { date: formatDateTime(passkey.created_at, i18n.locale) })}
								·
								{passkey.last_used_at
									? t('passkeys.lastUsed', { date: formatDateTime(passkey.last_used_at, i18n.locale) })
									: t('passkeys.neverUsed')}
							</div>
						</div>
						<Button
							variant="destructive"
							size="sm"
							disabled={passkeys.length <= 1}
							onclick={() => remove(passkey.id)}
							aria-label={t('passkeys.removeNamed', { name: passkey.name })}
						>
							{t('passkeys.remove')}
						</Button>
					</li>
				{/each}
			</ul>
			{#if passkeys.length <= 1}
				<p class="text-muted-foreground text-xs">{t('passkeys.lastHint')}</p>
			{/if}
			<form class="flex flex-wrap items-end gap-2" onsubmit={add}>
				<div class="space-y-2">
					<Label for="passkey-name">{t('passkeys.name')}</Label>
					<Input id="passkey-name" maxlength={80} bind:value={name} />
				</div>
				<Button type="submit" disabled={pending} data-testid="passkey-add">{t('passkeys.add')}</Button>
			</form>
		</Card.Content>
	</Card.Root>

	<RecoveryCodes />
</div>
