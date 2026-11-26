<script lang="ts">
	import { onMount } from 'svelte';
	import Building from '@lucide/svelte/icons/building-2';
	import KeyRound from '@lucide/svelte/icons/key-round';
	import Puzzle from '@lucide/svelte/icons/puzzle';
	import UserCheck from '@lucide/svelte/icons/user-check';
	import KpiCard from '#lib/components/app/KpiCard.svelte';
	import { meApi } from '#lib/api/client';
	import * as Alert from '#lib/components/ui/alert';
	import * as Card from '#lib/components/ui/card';
	import { Button } from '#lib/components/ui/button';
	import { errorMessage, t, type MessageKey } from '#lib/i18n/index.svelte';
	import ProcessingCard from '#lib/modules-impl/dms/ProcessingCard.svelte';
	import { session } from '#lib/session.svelte';
	import { workspace } from '#lib/workspace.svelte';

	/** Below this many unused recovery codes the dashboard asks the user to create new ones. */
	const RECOVERY_LOW = 3;

	let error = $state<string | null>(null);
	let pending = $state(false);
	let recoveryRemaining = $state<number | null>(null);

	const tenants = $derived(session.current?.memberships ?? []);
	const activeModules = $derived((workspace.modules?.items ?? []).filter((m) => workspace.moduleEffective(m.key)).length);

	async function loadRecoveryStatus() {
		try {
			recoveryRemaining = (await meApi.recoveryCodeStatus()).remaining;
		} catch {
			recoveryRemaining = null; // the hint is optional
		}
	}

	// A recovery (emergency) session may only add a passkey until it has been upgraded.
	onMount(() => {
		if (!session.isRecovery) void loadRecoveryStatus();
	});

	async function addPasskey() {
		pending = true;
		error = null;
		try {
			await session.addPasskey(t('dashboard.recovery.passkeyName'));
			await workspace.init();
			void loadRecoveryStatus();
		} catch (e) {
			error = errorMessage(e);
		} finally {
			pending = false;
		}
	}
</script>

<svelte:head><title>{t('dashboard.title')} · {t('app.name')}</title></svelte:head>

<div class="mb-7">
	<h1 class="page-title" data-testid="dashboard-heading">
		{t('dashboard.greeting', { name: session.current?.user.display_name ?? '' })}
	</h1>
	<p class="text-muted-foreground mt-1">{t('dashboard.subtitle')}</p>
</div>

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
	{#if recoveryRemaining !== null && recoveryRemaining < RECOVERY_LOW}
		<Alert.Root class="mb-4" data-testid="recovery-hint">
			<Alert.Title>{t('dashboard.recoveryHint.title')}</Alert.Title>
			<Alert.Description>
				<p>{t('dashboard.recoveryHint.text', { count: recoveryRemaining })}</p>
				<a class="text-ui-accent-ink mt-2 inline-block underline" href="/settings/security">{t('dashboard.recoveryHint.link')}</a>
			</Alert.Description>
		</Alert.Root>
	{/if}
	<div class="mb-5 grid grid-cols-2 gap-3 md:gap-4 min-[1101px]:grid-cols-4" data-testid="kpis">
		<KpiCard label={t('dashboard.kpi.tenants')} value={String(tenants.length)} hint={t('dashboard.kpi.tenantsHint')} icon={Building} testid="kpi-tenants" />
		<KpiCard
			label={t('dashboard.kpi.role')}
			value={workspace.detail ? t(`role.${workspace.detail.role}` as MessageKey) : '–'}
			hint={workspace.detail?.name}
			icon={UserCheck}
			testid="kpi-role"
		/>
		<KpiCard label={t('dashboard.kpi.modules')} value={workspace.detail ? String(activeModules) : '–'} hint={t('dashboard.kpi.modulesHint')} icon={Puzzle} testid="kpi-modules" />
		<KpiCard label={t('dashboard.kpi.recovery')} value={recoveryRemaining === null ? '–' : String(recoveryRemaining)} hint={t('dashboard.kpi.recoveryHint')} icon={KeyRound} testid="kpi-recovery" />
	</div>
	<Card.Root>
		<Card.Header><Card.Title><h2 class="text-[17px] font-semibold">{t('dashboard.tenants')}</h2></Card.Title></Card.Header>
		<Card.Content>
			{#if tenants.length === 0}
				<p class="text-muted-foreground text-sm">{t('dashboard.noTenants')}</p>
			{:else}
				<ul class="space-y-1" data-testid="tenant-list">
					{#each tenants as tenant (tenant.tenant_id)}
						<li>{tenant.name} <span class="text-muted-foreground text-sm">({t(`role.${tenant.role}` as MessageKey)})</span></li>
					{/each}
				</ul>
			{/if}
		</Card.Content>
	</Card.Root>
	{#if workspace.activeId && workspace.moduleEffective('dms') && workspace.can('dms.document.read')}
		<div class="mt-4">
			{#key workspace.activeId}<ProcessingCard tenant={workspace.activeId} />{/key}
		</div>
	{/if}
{/if}
