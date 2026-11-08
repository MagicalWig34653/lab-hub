<script lang="ts">
	import { onDestroy } from 'svelte';
	import { dmsAdminApi, type DmsExport, type DmsExportParams } from '#lib/api/client';
	import ErrorBanner from '#lib/components/app/ErrorBanner.svelte';
	import { Button } from '#lib/components/ui/button';
	import { Input } from '#lib/components/ui/input';
	import { formatBytes, formatDate, formatDateTime } from '#lib/format';
	import { errorMessage, i18n, tx } from '#lib/i18n/index.svelte';
	import { loadMasters, nameOf, type Masters } from './masters';

	let { tenant }: { tenant: string } = $props();
	// svelte-ignore state_referenced_locally
	const tenantId = tenant;

	const stateText = {
		queued: 'dms.exports.state.queued',
		running: 'dms.exports.state.running',
		done: 'dms.exports.state.done',
		failed: 'dms.exports.state.failed'
	} as const;
	const errorText = {
		integrity_failed: 'dms.exports.error.integrity_failed',
		export_too_large: 'dms.exports.error.export_too_large',
		export_failed: 'dms.exports.error.export_failed'
	} as const;

	let jobs = $state<DmsExport[]>([]);
	let masters = $state<Masters>({ types: [], tags: [], fields: [], paths: [], contacts: [] });
	let loading = $state(true);
	let starting = $state(false);
	let error = $state<string | null>(null);
	let dateFrom = $state('');
	let dateTo = $state('');
	let typeId = $state('');
	let timer: ReturnType<typeof setTimeout> | undefined;
	let destroyed = false;

	const isOpen = (j: DmsExport) => j.state === 'queued' || j.state === 'running';

	async function load() {
		try {
			jobs = (await dmsAdminApi.exports(tenantId)).items;
			error = null;
		} catch (e) {
			error = errorMessage(e);
		} finally {
			loading = false;
		}
		clearTimeout(timer);
		if (!destroyed && jobs.some(isOpen)) timer = setTimeout(() => void load(), 1500);
	}

	void loadMasters(tenantId).then((m) => (masters = m));
	void load();
	onDestroy(() => {
		destroyed = true;
		clearTimeout(timer);
	});

	async function start(event: SubmitEvent) {
		event.preventDefault();
		if (dateFrom && dateTo && dateFrom > dateTo) {
			error = tx('dms.exports.rangeInvalid');
			return;
		}
		starting = true;
		error = null;
		const params: DmsExportParams = {};
		if (dateFrom) params.date_from = dateFrom;
		if (dateTo) params.date_to = dateTo;
		if (typeId) params.document_type_id = typeId;
		try {
			const job = await dmsAdminApi.startExport(tenantId, params);
			jobs = [job, ...jobs.filter((j) => j.id !== job.id)];
			clearTimeout(timer);
			timer = setTimeout(() => void load(), 800);
		} catch (e) {
			error = errorMessage(e);
		} finally {
			starting = false;
		}
	}

	function scope(job: DmsExport): string {
		const parts: string[] = [];
		if (job.params.date_from || job.params.date_to) {
			parts.push(`${formatDate(job.params.date_from, i18n.locale) || '…'} – ${formatDate(job.params.date_to, i18n.locale) || '…'}`);
		}
		if (job.params.document_type_id) parts.push(nameOf(masters.types, job.params.document_type_id) || job.params.document_type_id.slice(0, 8));
		if (job.params.document_ids) parts.push(tx('dms.exports.selected', { count: job.params.document_ids.length }));
		return parts.length > 0 ? parts.join(' · ') : tx('dms.exports.scopeAll');
	}
</script>

<h1 class="mb-1 text-2xl font-semibold" data-testid="exports-title">{tx('dms.exports.title')}</h1>
<p class="text-muted-foreground mb-1 text-sm">{tx('dms.exports.intro')}</p>
<p class="text-muted-foreground mb-4 text-xs">{tx('dms.exports.gobdNote')}</p>
<ErrorBanner message={error} />

<form onsubmit={start} class="mb-5 flex flex-wrap items-end gap-3 rounded-lg border p-3" data-testid="export-form">
	<label class="text-sm">
		<span class="mb-1 block">{tx('dms.filter.dateFrom')}</span>
		<Input type="date" class="w-44" bind:value={dateFrom} data-testid="export-from" />
	</label>
	<label class="text-sm">
		<span class="mb-1 block">{tx('dms.filter.dateTo')}</span>
		<Input type="date" class="w-44" bind:value={dateTo} data-testid="export-to" />
	</label>
	<label class="text-sm">
		<span class="mb-1 block">{tx('dms.field.type')}</span>
		<select class="border-input bg-background h-8 rounded-lg border px-2 text-sm" bind:value={typeId} data-testid="export-type">
			<option value="">{tx('dms.filter.all')}</option>
			{#each masters.types as type (type.id)}<option value={type.id}>{type.name}</option>{/each}
		</select>
	</label>
	<Button type="submit" disabled={starting} data-testid="export-start">{tx('dms.exports.start')}</Button>
</form>
<p class="text-muted-foreground mb-3 text-xs">{tx('dms.exports.trashExcluded')}</p>

{#if loading}
	<p class="text-muted-foreground text-sm">{tx('common.loading')}</p>
{:else if jobs.length === 0}
	<p class="text-muted-foreground" data-testid="exports-empty">{tx('dms.exports.empty')}</p>
{:else}
	<ul class="space-y-3" data-testid="exports-list">
		{#each jobs as job (job.id)}
			<li class="rounded-lg border p-3" data-testid="export-row" data-state={job.state}>
				<div class="flex flex-wrap items-center justify-between gap-3">
					<div>
						<p class="text-sm font-medium" data-testid="export-state">{tx(stateText[job.state])}</p>
						<p class="text-muted-foreground text-xs">{formatDateTime(job.created_at, i18n.locale)} · {scope(job)}</p>
					</div>
					{#if job.state === 'done'}
						<a
							href={dmsAdminApi.exportFileUrl(tenantId, job.id)}
							download
							class="bg-primary text-primary-foreground hover:bg-primary/80 focus-visible:ring-ring/50 inline-flex h-8 items-center rounded-lg px-2.5 text-sm font-medium focus-visible:ring-3"
							data-testid="export-download"
						>
							{tx('dms.exports.download')}
						</a>
					{/if}
				</div>
				{#if isOpen(job)}
					<p role="status" class="text-muted-foreground mt-2 text-sm">{tx('dms.exports.running')}</p>
				{/if}
				{#if job.state === 'failed'}
					<p role="alert" class="text-destructive mt-2 text-sm" data-testid="export-error">
						{job.error_code && job.error_code in errorText ? tx(errorText[job.error_code as keyof typeof errorText]) : tx('dms.exports.error.export_failed')}
					</p>
				{/if}
				{#if job.state === 'done'}
					<dl class="mt-2 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
						<dt class="text-muted-foreground">{tx('dms.exports.documents')}</dt>
						<dd data-testid="export-documents">{job.document_count ?? 0}</dd>
						<dt class="text-muted-foreground">{tx('dms.exports.files')}</dt>
						<dd>{job.file_count ?? 0}</dd>
						<dt class="text-muted-foreground">{tx('dms.exports.size')}</dt>
						<dd>{formatBytes(job.size_bytes ?? 0, i18n.locale)}</dd>
						<dt class="text-muted-foreground">{tx('dms.exports.sha')}</dt>
						<dd class="font-mono text-xs break-all">{job.sha256 ?? ''}</dd>
						<dt class="text-muted-foreground">{tx('dms.exports.manifestSha')}</dt>
						<dd class="font-mono text-xs break-all">{job.manifest_sha256 ?? ''}</dd>
					</dl>
				{/if}
			</li>
		{/each}
	</ul>
{/if}
