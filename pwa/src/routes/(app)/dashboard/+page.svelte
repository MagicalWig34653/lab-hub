<script lang="ts">
	import { onMount } from 'svelte';
	import { tenantApi, type TenantMembership } from '#lib/api/client';
	import * as Alert from '#lib/components/ui/alert';
	import * as Card from '#lib/components/ui/card';
	import { Button } from '#lib/components/ui/button';
	import { errorMessage, t, type MessageKey } from '#lib/i18n/index.svelte';
	import { session } from '#lib/session.svelte';

	let tenants = $state<TenantMembership[]>([]);
	let error = $state<string | null>(null);
	let pending = $state(false);

	async function loadTenants() {
		try {
			tenants = (await tenantApi.list()).items;
		} catch (e) {
			error = errorMessage(e);
		}
	}

	// A recovery (emergency) session may not list tenants until it has been upgraded with a new passkey.
	onMount(() => {
		if (!session.isRecovery) void loadTenants();
	});

	async function addPasskey() {
		pending = true;
		error = null;
		try {
			await session.addPasskey(t('dashboard.recovery.passkeyName'));
			await loadTenants();
		} catch (e) {
			error = errorMessage(e);
		} finally {
			pending = false;
		}
	}
</script>

<svelte:head><title>{t('dashboard.title')} · {t('app.name')}</title></svelte:head>

<h1 class="mb-4 text-2xl font-semibold" data-testid="dashboard-heading">
	{t('dashboard.greeting', { name: session.current?.user.display_name ?? '' })}
</h1>

{#if error}
	<div role="alert" class="mb-4">
		<Alert.Root variant="destructive"><Alert.Description>{error}</Alert.Description></Alert.Root>
	</div>
{/if}

{#if session.isRecovery}
	<Alert.Root class="mb-4" data-testid="recovery-banner">
		<Alert.Title>{t('dashboard.recovery.title')}</Alert.Title>
		<Alert.Description>
			<p>{t('dashboard.recovery.text')}</p>
			<Button class="mt-2" disabled={pending} onclick={addPasskey} data-testid="recovery-add-passkey">
				{t('dashboard.recovery.addPasskey')}
			</Button>
		</Alert.Description>
	</Alert.Root>
{:else}
	<Card.Root>
		<Card.Header><Card.Title><h2 class="text-lg font-semibold">{t('dashboard.tenants')}</h2></Card.Title></Card.Header>
		<Card.Content>
			{#if tenants.length === 0}
				<p class="text-muted-foreground text-sm">{t('dashboard.noTenants')}</p>
			{:else}
				<ul class="space-y-1" data-testid="tenant-list">
					{#each tenants as tenant (tenant.id)}
						<li>{tenant.name} <span class="text-muted-foreground text-sm">({t(`role.${tenant.role}` as MessageKey)})</span></li>
					{/each}
				</ul>
			{/if}
		</Card.Content>
	</Card.Root>
{/if}
