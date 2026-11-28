<script lang="ts">
	import { onDestroy } from 'svelte';
	import { ApiError, dmsImportApi, type DmsImport, type DmsImportReport } from '#lib/api/client';
	import ErrorBanner from '#lib/components/app/ErrorBanner.svelte';
	import PageHeader from '#lib/components/app/PageHeader.svelte';
	import { Button } from '#lib/components/ui/button';
	import { Input } from '#lib/components/ui/input';
	import { formatDateTime } from '#lib/format';
	import { errorMessage, i18n, tx } from '#lib/i18n/index.svelte';
	import { workspace } from '#lib/workspace.svelte';
	import { emptyImportDraft, errorKeyFor, importErrorKeys, isOpen, percentDone, stateKeys, takeImportInput } from './import';
	import ImportReport from './ImportReport.svelte';
	import { P } from './permissions';

	let { tenant }: { tenant: string } = $props();
	// svelte-ignore state_referenced_locally
	const tenantId = tenant;

	/** The token is bound to the field only; it is never written to any browser storage, URL or log. */
	let draft = $state(emptyImportDraft());
	let runs = $state<DmsImport[]>([]);
	let selectedId = $state<string | null>(null);
	let reports = $state<Record<string, DmsImportReport>>({});
	let loading = $state(true);
	let starting = $state(false);
	let error = $state<string | null>(null);
	let formError = $state<string | null>(null);
	let timer: ReturnType<typeof setTimeout> | undefined;
	let destroyed = false;
	/** Counts the local changes: a list requested before a start or cancel is stale and must not replace the runs. */
	let version = 0;

	const canManage = $derived(workspace.can(P.importManage));
	const selected = $derived(runs.find((r) => r.id === selectedId) ?? runs[0] ?? null);
	const selectedReport = $derived(selected ? (reports[selected.id] ?? null) : null);

	async function loadReport() {
		const run = selected;
		if (!run || isOpen(run) || reports[run.id]) return;
		try {
			const report = await dmsImportApi.report(tenantId, run.id);
			reports = { ...reports, [run.id]: report };
		} catch (e) {
			// a run cancelled while it was still waiting has no report
			if (!(e instanceof ApiError && e.status === 404)) error = errorMessage(e);
		}
	}

	function schedule(delay: number) {
		clearTimeout(timer);
		if (!destroyed) timer = setTimeout(() => void load(), delay);
	}

	async function load() {
		clearTimeout(timer);
		const requested = version;
		try {
			const { items } = await dmsImportApi.list(tenantId);
			if (requested !== version) return schedule(500);
			runs = items;
			error = null;
			await loadReport();
		} catch (e) {
			error = errorMessage(e);
		} finally {
			loading = false;
		}
		if (runs.some(isOpen)) schedule(1000);
	}

	void load();
	onDestroy(() => {
		destroyed = true;
		draft.token = '';
		clearTimeout(timer);
	});

	const refused = (e: unknown, action: 'start' | 'cancel') => {
		const key = e instanceof ApiError ? errorKeyFor(e.status, e.fieldErrors, action) : null;
		return key ? tx(key) : errorMessage(e);
	};

	function put(run: DmsImport) {
		version += 1;
		runs = runs.some((r) => r.id === run.id) ? runs.map((r) => (r.id === run.id ? run : r)) : [run, ...runs];
	}

	async function start(event: SubmitEvent) {
		event.preventDefault();
		starting = true;
		formError = null;
		try {
			const run = await dmsImportApi.start(tenantId, takeImportInput(draft));
			put(run);
			selectedId = run.id;
			schedule(500);
		} catch (e) {
			formError = refused(e, 'start');
		} finally {
			starting = false;
		}
	}

	async function cancel(run: DmsImport) {
		error = null;
		try {
			put(await dmsImportApi.cancel(tenantId, run.id));
			schedule(500);
		} catch (e) {
			const message = refused(e, 'cancel');
			await load();
			error = message;
		}
	}

	function show(run: DmsImport) {
		selectedId = run.id;
		void loadReport();
	}

	function chooseKind() {
		draft.token = '';
		formError = null;
	}

	const sourceText = (run: DmsImport) => run.config.base_url ?? run.config.path ?? '';
	const radio = 'border-input has-checked:border-primary has-checked:bg-primary/5 flex cursor-pointer items-start gap-3 rounded-lg border p-3 text-sm';
</script>

<PageHeader title={tx('dms.import.title')} lead={tx('dms.import.intro')} testid="import-title" />
<ErrorBanner message={error} />

{#if canManage}
	<form onsubmit={start} class="panel mb-5 space-y-4" data-testid="import-form" autocomplete="off" novalidate>
		<fieldset>
			<legend class="mb-2 text-sm font-medium">{tx('dms.import.source')}</legend>
			<div class="grid gap-2 sm:grid-cols-2">
				<label class={radio}>
					<input type="radio" class="mt-1" value="api" bind:group={draft.kind} onchange={chooseKind} data-testid="import-kind-api" />
					<span><span class="block font-medium">{tx('dms.import.kind.api')}</span><span class="text-muted-foreground text-xs">{tx('dms.import.kind.apiHint')}</span></span>
				</label>
				<label class={radio}>
					<input type="radio" class="mt-1" value="export" bind:group={draft.kind} onchange={chooseKind} data-testid="import-kind-export" />
					<span><span class="block font-medium">{tx('dms.import.kind.export')}</span><span class="text-muted-foreground text-xs">{tx('dms.import.kind.exportHint')}</span></span>
				</label>
			</div>
		</fieldset>

		{#if draft.kind === 'api'}
			<div class="grid gap-4 sm:grid-cols-2">
				<div class="text-sm">
					<label class="mb-1 block" for="import-base-url">{tx('dms.import.baseUrl')}</label>
					<Input id="import-base-url" inputmode="url" autocapitalize="none" autocomplete="off" spellcheck={false} bind:value={draft.baseUrl} aria-describedby="import-base-url-hint" data-testid="import-base-url" />
					<p id="import-base-url-hint" class="text-muted-foreground mt-1 text-xs break-words">{tx('dms.import.baseUrlHint')}</p>
				</div>
				<div class="text-sm">
					<label class="mb-1 block" for="import-token">{tx('dms.import.token')}</label>
					<!-- no name and autocomplete off: the browser is asked not to keep the value -->
					<Input id="import-token" type="password" autocomplete="off" autocapitalize="none" spellcheck={false} data-1p-ignore data-lpignore="true" bind:value={draft.token} aria-describedby="import-token-hint" data-testid="import-token" />
					<p id="import-token-hint" class="text-muted-foreground mt-1 text-xs">{tx('dms.import.tokenHint')}</p>
				</div>
			</div>
		{:else}
			<div class="text-sm sm:max-w-md">
				<label class="mb-1 block" for="import-path">{tx('dms.import.path')}</label>
				<Input id="import-path" autocapitalize="none" autocomplete="off" spellcheck={false} bind:value={draft.path} aria-describedby="import-path-hint" data-testid="import-path" />
				<p id="import-path-hint" class="text-muted-foreground mt-1 text-xs">{tx('dms.import.pathHint')}</p>
			</div>
		{/if}

		<fieldset>
			<legend class="mb-2 text-sm font-medium">{tx('dms.import.mode')}</legend>
			<div class="grid gap-2 sm:grid-cols-2">
				<label class={radio}>
					<input type="radio" class="mt-1" value="dry_run" bind:group={draft.mode} data-testid="import-mode-dry_run" />
					<span><span class="block font-medium">{tx('dms.import.mode.dry_run')}</span><span class="text-muted-foreground text-xs">{tx('dms.import.mode.dry_runHint')}</span></span>
				</label>
				<label class={radio}>
					<input type="radio" class="mt-1" value="import" bind:group={draft.mode} data-testid="import-mode-import" />
					<span><span class="block font-medium">{tx('dms.import.mode.import')}</span><span class="text-muted-foreground text-xs">{tx('dms.import.mode.importHint')}</span></span>
				</label>
			</div>
		</fieldset>

		{#if draft.mode === 'import'}
			<p class="text-sm" data-testid="import-writes-hint">{tx('dms.import.writesHint')}</p>
			<label class="flex items-start gap-2 text-sm">
				<input type="checkbox" class="mt-1" bind:checked={draft.ocr} data-testid="import-ocr" />
				{tx('dms.import.ocr')}
			</label>
		{/if}

		{#if formError}<p role="alert" class="text-destructive text-sm" data-testid="import-form-error">{formError}</p>{/if}
		<Button type="submit" disabled={starting} data-testid="import-start">{tx(draft.mode === 'dry_run' ? 'dms.import.start.dry_run' : 'dms.import.start.import')}</Button>
	</form>
{/if}

<h2 class="panel-title mb-2">{tx('dms.import.runs')}</h2>
{#if loading}
	<p class="text-muted-foreground text-sm">{tx('common.loading')}</p>
{:else if runs.length === 0}
	<p class="panel text-muted-foreground text-center text-sm" data-testid="import-empty">{tx('dms.import.empty')}</p>
{:else}
	<ul class="space-y-3" data-testid="import-runs">
		{#each runs as run (run.id)}
			{@const percent = percentDone(run)}
			<li class="bg-card rounded-[10px] border p-4" class:border-primary={selected?.id === run.id && runs.length > 1} data-testid="import-run" data-state={run.state}>
				<div class="flex flex-wrap items-start justify-between gap-3">
					<div class="min-w-0">
						<p class="text-sm font-medium">
							{tx(run.mode === 'dry_run' ? 'dms.import.mode.dry_run' : 'dms.import.mode.import')} · <span data-testid="import-state">{tx(stateKeys[run.state])}</span>
						</p>
						<p class="text-muted-foreground text-xs break-all">{formatDateTime(run.created_at, i18n.locale)} · {sourceText(run)}</p>
					</div>
					<div class="flex gap-2">
						{#if isOpen(run) && canManage && !run.cancel_requested}
							<Button type="button" size="sm" variant="outline" onclick={() => void cancel(run)} data-testid="import-cancel">{tx('dms.import.cancel')}</Button>
						{/if}
						{#if !isOpen(run)}
							<Button type="button" size="sm" variant="outline" aria-pressed={selected?.id === run.id} onclick={() => show(run)} data-testid="import-show">{tx('dms.import.showReport')}</Button>
						{/if}
					</div>
				</div>
				{#if isOpen(run)}
					<div class="mt-3">
						{#if percent === null}
							<progress class="import-progress" aria-label={tx('dms.import.progress')}></progress>
						{:else}
							<progress class="import-progress" max="100" value={percent} aria-label={tx('dms.import.progress')}></progress>
						{/if}
						<p role="status" class="text-muted-foreground mt-1 text-sm" data-testid="import-progress">
							{#if run.state === 'queued'}
								{tx('dms.import.progressWaiting')}
							{:else if percent === null}
								{tx('dms.import.progressUnknown')}
							{:else}
								{tx('dms.import.progressOf', { processed: run.progress.processed ?? 0, total: run.progress.total })}
							{/if}
						</p>
						{#if run.cancel_requested}
							<p role="status" class="mt-1 text-sm" data-testid="import-cancel-requested">{tx('dms.import.cancelRequested')}</p>
						{/if}
					</div>
				{:else if run.state === 'failed'}
					<p class="text-destructive mt-2 text-sm" data-testid="import-run-error">{tx(importErrorKeys[run.error_code ?? ''] ?? 'dms.import.error.import_failed')}</p>
				{/if}
			</li>
		{/each}
	</ul>
	{#if selected && isOpen(selected)}
		<p class="text-muted-foreground mt-4 text-sm">{tx('dms.import.report.running')}</p>
	{:else if selected && selectedReport}
		<ImportReport tenant={tenantId} run={selected} report={selectedReport} />
	{/if}
{/if}

<style>
	.import-progress {
		display: block;
		width: 100%;
		height: 0.5rem;
		appearance: none;
		border: 0;
		border-radius: 999px;
		overflow: hidden;
		background: var(--muted);
	}
	.import-progress::-webkit-progress-bar {
		background: var(--muted);
	}
	.import-progress::-webkit-progress-value {
		background: var(--primary);
		transition: width 0.3s;
	}
	.import-progress::-moz-progress-bar {
		background: var(--primary);
	}
</style>
