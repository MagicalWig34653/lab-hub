<script lang="ts">
	import { dmsAdminApi, type DmsRule } from '#lib/api/client';
	import ConfirmDialog from '#lib/components/app/ConfirmDialog.svelte';
	import ErrorBanner from '#lib/components/app/ErrorBanner.svelte';
	import { Button } from '#lib/components/ui/button';
	import { errorMessage, tx } from '#lib/i18n/index.svelte';
	import { workspace } from '#lib/workspace.svelte';
	import { loadMasters, type Masters } from './masters';
	import { P } from './permissions';
	import RuleEditor from './RuleEditor.svelte';

	let { tenant }: { tenant: string } = $props();
	// svelte-ignore state_referenced_locally
	const tenantId = tenant;

	const canManage = $derived(workspace.can(P.ruleManage));

	let rules = $state<DmsRule[]>([]);
	let masters = $state<Masters>({ types: [], tags: [], fields: [], paths: [], contacts: [] });
	let loading = $state(true);
	let error = $state<string | null>(null);
	/** `undefined`: list; `null`: new rule; a rule: editing it. */
	let editing = $state<DmsRule | null | undefined>(undefined);
	let deleting = $state<DmsRule | null>(null);
	let deleteBusy = $state(false);
	let deleteError = $state<string | null>(null);
	let saved = $state(false);

	async function load() {
		loading = true;
		error = null;
		try {
			rules = (await dmsAdminApi.rules(tenantId)).items;
		} catch (e) {
			error = errorMessage(e);
		} finally {
			loading = false;
		}
	}

	void loadMasters(tenantId).then((m) => (masters = m));
	void load();

	async function onSaved() {
		editing = undefined;
		saved = true;
		await load();
	}

	async function confirmDelete() {
		if (!deleting) return;
		deleteBusy = true;
		deleteError = null;
		try {
			await dmsAdminApi.deleteRule(tenantId, deleting.id);
			deleting = null;
			await load();
		} catch (e) {
			deleteError = errorMessage(e);
		} finally {
			deleteBusy = false;
		}
	}
</script>

{#if editing !== undefined}
	<RuleEditor tenant={tenantId} rule={editing} {masters} onsaved={onSaved} oncancel={() => (editing = undefined)} />
{:else}
	<div class="mb-3 flex flex-wrap items-center justify-between gap-3">
		<h1 class="text-2xl font-semibold" data-testid="rules-title">{tx('dms.rules.title')}</h1>
		{#if canManage}
			<Button type="button" onclick={() => ((editing = null), (saved = false))} data-testid="rule-new">{tx('dms.rule.new')}</Button>
		{/if}
	</div>
	<p class="text-muted-foreground mb-4 text-sm">{tx('dms.rules.intro')}</p>
	<ErrorBanner message={error} />
	{#if saved}<p role="status" class="mb-3 text-sm" data-testid="rule-saved">{tx('dms.rule.saved')}</p>{/if}

	{#if loading}
		<p class="text-muted-foreground text-sm">{tx('common.loading')}</p>
	{:else if rules.length === 0 && !error}
		<p class="text-muted-foreground" data-testid="rules-empty">{tx('dms.rules.empty')}</p>
	{:else}
		<div class="overflow-x-auto">
			<table class="w-full text-left text-sm" data-testid="rules-table">
				<caption class="sr-only">{tx('dms.rules.title')}</caption>
				<thead>
					<tr class="text-muted-foreground border-b">
						<th scope="col" class="py-2 pr-3">{tx('dms.rule.name')}</th>
						<th scope="col" class="py-2 pr-3">{tx('dms.rule.priority')}</th>
						<th scope="col" class="py-2 pr-3">{tx('dms.rule.mode')}</th>
						<th scope="col" class="py-2 pr-3">{tx('dms.rules.stats')}</th>
						<th scope="col" class="py-2"><span class="sr-only">{tx('dms.actions.title')}</span></th>
					</tr>
				</thead>
				<tbody>
					{#each rules as rule (rule.id)}
						<tr class="border-b align-top" data-testid="rule-row" data-enabled={rule.enabled}>
							<td class="py-2 pr-3">
								<span class="font-medium">{rule.name}</span>
								{#if !rule.enabled}<span class="text-muted-foreground ml-2 text-xs">({tx('dms.rules.disabled')})</span>{/if}
								<span class="text-muted-foreground block text-xs">{tx('dms.rules.version', { version: rule.version })}</span>
							</td>
							<td class="py-2 pr-3">{rule.priority}</td>
							<td class="py-2 pr-3" data-testid="rule-mode-cell">{tx(rule.mode === 'auto' ? 'dms.rule.mode.auto' : 'dms.rule.mode.suggest')}</td>
							<td class="py-2 pr-3 text-xs">
								{tx('dms.rules.statsLine', {
									suggested: rule.stats.suggested,
									open: rule.stats.open,
									accepted: rule.stats.accepted,
									rejected: rule.stats.rejected,
									automatic: rule.stats.automatic
								})}
							</td>
							<td class="py-2">
								{#if canManage}
									<div class="flex flex-wrap gap-2">
										<Button type="button" size="sm" variant="outline" onclick={() => ((editing = rule), (saved = false))} data-testid="rule-edit">{tx('dms.rule.edit')}</Button>
										<Button type="button" size="sm" variant="outline" onclick={() => ((deleting = rule), (deleteError = null))} data-testid="rule-delete">{tx('dms.rule.delete')}</Button>
									</div>
								{/if}
							</td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
	{/if}
{/if}

<ConfirmDialog
	open={deleting !== null}
	title={tx('dms.rule.delete')}
	confirmLabel={tx('dms.rule.delete')}
	destructive
	busy={deleteBusy}
	error={deleteError}
	testid="rule-delete-dialog"
	onconfirm={confirmDelete}
	oncancel={() => (deleting = null)}
>
	<p>{tx('dms.rule.deleteText', { name: deleting?.name ?? '' })}</p>
</ConfirmDialog>
