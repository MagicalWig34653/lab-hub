<script lang="ts">
	import { dmsSourcesApi, type DmsSource, type DmsSourceTest } from '#lib/api/client';
	import ConfirmDialog from '#lib/components/app/ConfirmDialog.svelte';
	import ErrorBanner from '#lib/components/app/ErrorBanner.svelte';
	import { Button } from '#lib/components/ui/button';
	import { formatDateTime } from '#lib/format';
	import { errorMessage, i18n, tx } from '#lib/i18n/index.svelte';
	import { workspace } from '#lib/workspace.svelte';
	import { P } from './permissions';
	import SourceEditor from './SourceEditor.svelte';
	import { sourceErrorKey, statKeys, type SourceKind } from './sources';

	let { tenant }: { tenant: string } = $props();
	// svelte-ignore state_referenced_locally
	const tenantId = tenant;

	const canManage = $derived(workspace.can(P.sourceManage));

	let sources = $state<DmsSource[]>([]);
	let loading = $state(true);
	let error = $state<string | null>(null);
	/** `undefined`: list; otherwise the editor (new: `source` null). */
	let editing = $state<{ kind: SourceKind; source: DmsSource | null } | undefined>(undefined);
	let saved = $state<string | null>(null);
	let busyId = $state<string | null>(null);
	let tests = $state<Record<string, DmsSourceTest | 'running' | 'unsupported'>>({});
	let notes = $state<Record<string, string>>({});
	let deleting = $state<DmsSource | null>(null);
	let deleteBusy = $state(false);
	let deleteError = $state<string | null>(null);

	async function load() {
		loading = sources.length === 0;
		try {
			sources = (await dmsSourcesApi.list(tenantId)).items;
			error = null;
		} catch (e) {
			error = errorMessage(e);
		} finally {
			loading = false;
		}
	}
	void load();

	function replace(next: DmsSource) {
		sources = sources.map((s) => (s.id === next.id ? next : s));
	}

	async function onSaved(next: DmsSource) {
		saved = next.name;
		editing = undefined;
		await load();
	}

	async function runTest(source: DmsSource) {
		tests[source.id] = 'running';
		try {
			tests[source.id] = await dmsSourcesApi.test(tenantId, source.id);
		} catch (e) {
			delete tests[source.id];
			error = errorMessage(e);
		}
	}

	async function runNow(source: DmsSource) {
		busyId = source.id;
		error = null;
		try {
			replace(await dmsSourcesApi.run(tenantId, source.id));
			notes[source.id] = tx('dms.sources.runRequested');
		} catch (e) {
			error = errorMessage(e);
		} finally {
			busyId = null;
		}
	}

	async function toggle(source: DmsSource) {
		busyId = source.id;
		error = null;
		try {
			replace(await dmsSourcesApi.update(tenantId, source.id, { enabled: !source.enabled }));
			delete notes[source.id];
		} catch (e) {
			error = errorMessage(e);
		} finally {
			busyId = null;
		}
	}

	async function confirmDelete() {
		if (!deleting) return;
		deleteBusy = true;
		deleteError = null;
		try {
			await dmsSourcesApi.remove(tenantId, deleting.id);
			deleting = null;
			await load();
		} catch (e) {
			deleteError = errorMessage(e);
		} finally {
			deleteBusy = false;
		}
	}

	function summary(source: DmsSource): string {
		const c = source.config as Record<string, unknown>;
		if (source.kind === 'mail') return tx('dms.sources.summaryMail', { user: String(c.username ?? ''), host: String(c.host ?? ''), port: String(c.port ?? 993), mailbox: String(c.mailbox ?? 'INBOX') });
		return tx('dms.sources.summaryFolder', { path: String(c.path ?? '') });
	}
</script>

{#if editing !== undefined}
	<SourceEditor tenant={tenantId} kind={editing.kind} source={editing.source} onsaved={onSaved} oncancel={() => (editing = undefined)} />
{:else}
	<div class="mb-3 flex flex-wrap items-center justify-between gap-3">
		<h1 class="text-2xl font-semibold" data-testid="sources-title">{tx('dms.sources.title')}</h1>
		<div class="flex flex-wrap gap-2">
			<Button type="button" variant="outline" onclick={() => void load()} data-testid="source-refresh">{tx('dms.sources.refresh')}</Button>
			{#if canManage}
				<Button type="button" onclick={() => ((editing = { kind: 'mail', source: null }), (saved = null))} data-testid="source-new-mail">{tx('dms.sources.newMail')}</Button>
				<Button type="button" onclick={() => ((editing = { kind: 'folder', source: null }), (saved = null))} data-testid="source-new-folder">{tx('dms.sources.newFolder')}</Button>
			{/if}
		</div>
	</div>
	<p class="text-muted-foreground mb-4 text-sm">{tx('dms.sources.intro')}</p>
	<ErrorBanner message={error} />
	{#if saved}<p role="status" class="mb-3 text-sm" data-testid="source-saved">{tx('dms.sources.saved', { name: saved })}</p>{/if}

	{#if loading}
		<p class="text-muted-foreground text-sm">{tx('common.loading')}</p>
	{:else if sources.length === 0 && !error}
		<p class="text-muted-foreground" data-testid="sources-empty">{tx('dms.sources.empty')}</p>
	{:else}
		<ul class="space-y-3" data-testid="sources-list">
			{#each sources as source (source.id)}
				{@const test = tests[source.id]}
				<li class="rounded-lg border p-3" data-testid="source-row" data-enabled={source.enabled} data-kind={source.kind} data-status={source.last_status ?? 'none'}>
					<div class="flex flex-wrap items-start justify-between gap-3">
						<div>
							<h2 class="text-base font-medium">
								<span data-testid="source-row-name">{source.name}</span>
								<span class="text-muted-foreground ml-2 text-xs font-normal">{tx(source.kind === 'mail' ? 'dms.sources.kind.mail' : 'dms.sources.kind.folder')}</span>
							</h2>
							<p class="text-muted-foreground text-xs" data-testid="source-summary">{summary(source)}</p>
							<p class="mt-1 text-sm" data-testid="source-enabled-state">{tx(source.enabled ? 'dms.sources.enabled' : 'dms.sources.disabled')}</p>
						</div>
						{#if canManage}
							<div class="flex flex-wrap gap-2">
								{#if source.kind === 'mail'}
									<Button type="button" size="sm" variant="outline" disabled={test === 'running'} onclick={() => runTest(source)} data-testid="source-test">{tx('dms.sources.test')}</Button>
								{/if}
								<Button type="button" size="sm" variant="outline" disabled={busyId === source.id || !source.enabled} onclick={() => runNow(source)} data-testid="source-run">{tx('dms.sources.run')}</Button>
								<Button type="button" size="sm" variant="outline" disabled={busyId === source.id} onclick={() => toggle(source)} data-testid="source-toggle">
									{tx(source.enabled ? 'dms.sources.disable' : 'dms.sources.enable')}
								</Button>
								<Button type="button" size="sm" variant="outline" onclick={() => ((editing = { kind: source.kind, source }), (saved = null))} data-testid="source-edit">{tx('dms.sources.edit')}</Button>
								<Button type="button" size="sm" variant="outline" onclick={() => ((deleting = source), (deleteError = null))} data-testid="source-delete">{tx('dms.sources.delete')}</Button>
							</div>
						{/if}
					</div>

					<dl class="mt-2 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
						<dt class="text-muted-foreground">{tx('dms.sources.lastRun')}</dt>
						<dd data-testid="source-last-run">
							{#if source.last_run_at}
								{formatDateTime(source.last_run_at, i18n.locale)}
								·
								<span data-testid="source-last-status">{tx(source.last_status === 'ok' ? 'dms.sources.status.ok' : 'dms.sources.status.error')}</span>
							{:else}
								{tx('dms.sources.neverRun')}
							{/if}
						</dd>
						<dt class="text-muted-foreground">{tx('dms.sources.runs')}</dt>
						<dd>{source.runs}</dd>
						{#if source.last_stats}
							<dt class="text-muted-foreground">{tx('dms.sources.lastStats')}</dt>
							<dd data-testid="source-stats">
								{#each statKeys[source.kind] as stat (stat.key)}
									{#if stat.key in source.last_stats}<span class="mr-3 inline-block">{tx(stat.label, { count: source.last_stats[stat.key] })}</span>{/if}
								{/each}
							</dd>
						{/if}
					</dl>

					{#if source.last_error}
						<p role="alert" class="text-destructive mt-2 text-sm" data-testid="source-error" data-code={source.last_error}>{tx(sourceErrorKey(source.last_error), { code: source.last_error })}</p>
					{/if}
					{#if notes[source.id]}<p role="status" class="mt-2 text-sm" data-testid="source-note">{notes[source.id]}</p>{/if}
					{#if test === 'running'}
						<p role="status" class="text-muted-foreground mt-2 text-sm">{tx('dms.sources.testing')}</p>
					{:else if test && test !== 'unsupported'}
						{#if test.ok}
							<p role="status" class="mt-2 text-sm" data-testid="source-test-result" data-ok="true">{tx('dms.sources.testOk', { count: test.unseen ?? 0 })}</p>
						{:else}
							<p role="alert" class="text-destructive mt-2 text-sm" data-testid="source-test-result" data-ok="false" data-code={test.error ?? ''}>
								{tx('dms.sources.testFailed')} {tx(sourceErrorKey(test.error ?? ''), { code: test.error ?? '' })}
							</p>
						{/if}
					{/if}
					{#if source.kind === 'folder'}
						<p class="text-muted-foreground mt-2 text-xs">{tx('dms.sources.folderTestNote')}</p>
					{/if}
				</li>
			{/each}
		</ul>
	{/if}
{/if}

<ConfirmDialog
	open={deleting !== null}
	title={tx('dms.sources.delete')}
	confirmLabel={tx('dms.sources.delete')}
	destructive
	busy={deleteBusy}
	error={deleteError}
	testid="source-delete-dialog"
	onconfirm={confirmDelete}
	oncancel={() => (deleting = null)}
>
	<p>{tx('dms.sources.deleteText', { name: deleting?.name ?? '' })}</p>
</ConfirmDialog>
