<script lang="ts">
	import { onMount } from 'svelte';
	import Building from '@lucide/svelte/icons/building-2';
	import KeyRound from '@lucide/svelte/icons/key-round';
	import Puzzle from '@lucide/svelte/icons/puzzle';
	import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
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
		<div class="bg-card mb-5 flex flex-wrap items-center gap-x-4 gap-y-3 rounded-[10px] border p-4 shadow-(--shadow-card) md:px-6" role="status" data-testid="recovery-hint">
			<TriangleAlert class="text-ui-accent-ink size-5 shrink-0" aria-hidden="true" />
			<div class="min-w-0 flex-1 basis-60">
				<p class="font-semibold">{t('dashboard.recoveryHint.title')}</p>
				<p class="text-muted-foreground text-sm">
					{recoveryRemaining === 1 ? t('dashboard.recoveryHint.textOne') : t('dashboard.recoveryHint.text', { count: recoveryRemaining })}
				</p>
			</div>
			<Button variant="outline" class="max-sm:w-full" href="/settings/security">{t('dashboard.recoveryHint.link')}</Button>
		</div>
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
	<div class="grid items-start gap-4 min-[1101px]:grid-cols-2">
		<Card.Root>
			<Card.Header><Card.Title><h2 class="panel-title">{t('dashboard.tenants')}</h2></Card.Title></Card.Header>
			<Card.Content>
				{#if tenants.length === 0}
					<p class="text-muted-foreground text-sm">{t('dashboard.noTenants')}</p>
				{:else}
					<ul class="divide-y" data-testid="tenant-list">
						{#each tenants as tenant (tenant.tenant_id)}
							<li class="flex min-h-11 items-center justify-between gap-3 text-sm">
								<span class="min-w-0 font-medium break-words">{tenant.name}</span>
								<span class="bg-muted shrink-0 rounded-full px-2.5 py-0.5 text-xs font-medium">{t(`role.${tenant.role}` as MessageKey)}</span>
							</li>
						{/each}
					</ul>
				{/if}
			</Card.Content>
		</Card.Root>
		{#if workspace.activeId && workspace.moduleEffective('dms') && workspace.can('dms.document.read')}
			{#key workspace.activeId}<ProcessingCard tenant={workspace.activeId} />{/key}
		{/if}
	</div>
{/if}
