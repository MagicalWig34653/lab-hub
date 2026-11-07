<script lang="ts">
	import { tenantApi } from '#lib/api/client';
	import ErrorBanner from '#lib/components/app/ErrorBanner.svelte';
	import * as Alert from '#lib/components/ui/alert';
	import { Button } from '#lib/components/ui/button';
	import * as Card from '#lib/components/ui/card';
	import { errorMessage, t, tx } from '#lib/i18n/index.svelte';
	import { registry } from '#lib/modules/registry';
	import { workspace } from '#lib/workspace.svelte';

	let error = $state<string | null>(null);
	let busy = $state<string | null>(null);

	const canManage = $derived(workspace.can('tenant.module.manage'));
	const items = $derived(workspace.modules?.items ?? []);
	/** Navigation label of the module if the frontend knows one, else the bare key (module without frontend). */
	function label(key: string): string {
		const text = tx(`nav.${key}`);
		return text === `nav.${key}` ? key : text;
	}
	const hasManifest = (key: string) => registry.some((m) => m.key === key);

	async function toggle(key: string, enabled: boolean) {
		const tenant = workspace.activeId;
		if (!tenant) return;
		busy = key;
		error = null;
		try {
			await tenantApi.setModule(tenant, key, enabled);
		} catch (e) {
			error = errorMessage(e);
		} finally {
			// Always re-read: a conflict (module_requires, module_required_by) means the shown state may be stale.
			await workspace.refreshModules();
			busy = null;
		}
	}
</script>

<svelte:head><title>{t('settings.modules')} · {t('app.name')}</title></svelte:head>

{#if !canManage}
	<Alert.Root data-testid="modules-forbidden"><Alert.Description>{t('error.forbidden')}</Alert.Description></Alert.Root>
{:else}
	<Card.Root>
		<Card.Header>
			<Card.Title><h2 class="text-lg font-semibold">{t('modules.title')}</h2></Card.Title>
			<Card.Description>{t('modules.description', { tenant: workspace.detail?.name ?? '' })}</Card.Description>
		</Card.Header>
		<Card.Content class="space-y-4">
			<ErrorBanner message={error} />
			{#if items.length === 0}
				<p class="text-muted-foreground text-sm">{t('modules.none')}</p>
			{/if}
			<ul class="divide-y" data-testid="module-list">
				{#each items as item (item.key)}
					<li class="flex flex-wrap items-center justify-between gap-2 py-3" data-module={item.key} data-enabled={item.enabled}>
						<div>
							<div class="font-medium">{label(item.key)}</div>
							<div class="text-muted-foreground text-xs">
								{#if !item.installed}
									{t('modules.notInstalled')}
								{:else if item.effective}
									{t('modules.stateOn')}
								{:else if item.enabled}
									{t('modules.stateWaiting')}
								{:else}
									{t('modules.stateOff')}
								{/if}
								{#if item.requires.length > 0}· {t('modules.requires', { modules: item.requires.join(', ') })}{/if}
								{#if !hasManifest(item.key)}· {t('modules.apiOnly')}{/if}
							</div>
						</div>
						<Button
							variant={item.enabled ? 'outline' : 'default'}
							size="sm"
							disabled={busy !== null || !item.installed}
							aria-pressed={item.enabled}
							onclick={() => toggle(item.key, !item.enabled)}
							data-testid={`module-toggle-${item.key}`}
						>
							{item.enabled ? t('modules.disable') : t('modules.enable')}
						</Button>
					</li>
				{/each}
			</ul>
			{#if workspace.navigation.unavailable.length > 0}
				<p class="text-muted-foreground text-sm" data-testid="modules-api-only">
					{t('modules.apiOnlyList', { modules: workspace.navigation.unavailable.join(', ') })}
				</p>
			{/if}
		</Card.Content>
	</Card.Root>
{/if}
