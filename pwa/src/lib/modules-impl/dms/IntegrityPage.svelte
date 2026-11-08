<script lang="ts">
	import { onDestroy } from 'svelte';
	import { dmsAdminApi, type DmsIntegrityRun } from '#lib/api/client';
	import ErrorBanner from '#lib/components/app/ErrorBanner.svelte';
	import * as Alert from '#lib/components/ui/alert';
	import { Button } from '#lib/components/ui/button';
	import { formatDateTime } from '#lib/format';
	import { errorMessage, i18n, tx } from '#lib/i18n/index.svelte';

	let { tenant }: { tenant: string } = $props();
	// svelte-ignore state_referenced_locally
	const tenantId = tenant;

	const stateText = {
		queued: 'dms.integrity.state.queued',
		running: 'dms.integrity.state.running',
		passed: 'dms.integrity.state.passed',
		failed: 'dms.integrity.state.failed',
		error: 'dms.integrity.state.error'
	} as const;
	const problemText = {
		hash_mismatch: 'dms.integrity.problem.hash_mismatch',
		size_mismatch: 'dms.integrity.problem.size_mismatch',
		missing: 'dms.integrity.problem.missing',
		record_mismatch: 'dms.integrity.problem.record_mismatch'
	} as const;
	const chainProblemText = {
		hash_mismatch: 'dms.integrity.chain.hash_mismatch',
		prev_mismatch: 'dms.integrity.chain.prev_mismatch',
		missing_audit: 'dms.integrity.chain.missing_audit',
		sequence_gap: 'dms.integrity.chain.sequence_gap',
		unchained_audit: 'dms.integrity.chain.unchained_audit',
		head_mismatch: 'dms.integrity.chain.head_mismatch'
	} as const;

	let runs = $state<DmsIntegrityRun[]>([]);
	let selectedId = $state<string | null>(null);
	let loading = $state(true);
	let starting = $state(false);
	let error = $state<string | null>(null);
	let timer: ReturnType<typeof setTimeout> | undefined;
	let destroyed = false;

	const selected = $derived(runs.find((r) => r.id === selectedId) ?? runs[0] ?? null);
	/** Head of the newest run that reports one: the anchor to store outside the database. */
	const head = $derived(runs.find((r) => r.report?.chain?.head)?.report?.chain?.head ?? null);
	const isOpen = (r: DmsIntegrityRun) => r.state === 'queued' || r.state === 'running';

	async function load() {
		try {
			runs = (await dmsAdminApi.integrityRuns(tenantId)).items;
			error = null;
		} catch (e) {
			error = errorMessage(e);
		} finally {
			loading = false;
		}
		clearTimeout(timer);
		if (!destroyed && runs.some(isOpen)) timer = setTimeout(() => void load(), 1500);
	}

	void load();
	onDestroy(() => {
		destroyed = true;
		clearTimeout(timer);
	});

	async function start() {
		starting = true;
		error = null;
		try {
			const run = await dmsAdminApi.startIntegrityRun(tenantId);
			selectedId = run.id;
			runs = [run, ...runs.filter((r) => r.id !== run.id)];
			clearTimeout(timer);
			timer = setTimeout(() => void load(), 800);
		} catch (e) {
			error = errorMessage(e);
		} finally {
			starting = false;
		}
	}

	const when = (v: string | null | undefined) => (v ? formatDateTime(v, i18n.locale) : '–');
	const chainOk = (r: DmsIntegrityRun) => (r.chain_ok === null || r.chain_ok === undefined ? '–' : tx(r.chain_ok ? 'dms.masters.yes' : 'dms.masters.no'));
</script>

<h1 class="mb-1 text-2xl font-semibold" data-testid="integrity-title">{tx('dms.integrity.title')}</h1>
<p class="text-muted-foreground mb-1 text-sm">{tx('dms.integrity.intro')}</p>
<p class="text-muted-foreground mb-4 text-xs">{tx('dms.integrity.gobdNote')}</p>
<ErrorBanner message={error} />

<div class="mb-4 flex flex-wrap items-center gap-3">
	<Button type="button" disabled={starting || runs.some(isOpen)} onclick={start} data-testid="integrity-start">{tx('dms.integrity.start')}</Button>
	<p role="status" class="text-sm" data-testid="integrity-running">{runs.some(isOpen) ? tx('dms.integrity.running') : ''}</p>
</div>

<section class="mb-5 rounded-lg border p-3" aria-labelledby="integrity-head-title">
	<h2 id="integrity-head-title" class="mb-1 text-base font-medium">{tx('dms.integrity.headTitle')}</h2>
	{#if head}
		<p class="font-mono text-xs break-all" data-testid="integrity-head">{head}</p>
		<p class="text-muted-foreground mt-1 text-xs">{tx('dms.integrity.headHint')}</p>
	{:else}
		<p class="text-muted-foreground text-sm" data-testid="integrity-head-none">{tx('dms.integrity.headNone')}</p>
	{/if}
</section>

{#if loading}
	<p class="text-muted-foreground text-sm">{tx('common.loading')}</p>
{:else if runs.length === 0}
	<p class="text-muted-foreground" data-testid="integrity-empty">{tx('dms.integrity.empty')}</p>
{:else}
	<div class="overflow-x-auto">
		<table class="w-full text-left text-sm" data-testid="integrity-runs">
			<caption class="sr-only">{tx('dms.integrity.runs')}</caption>
			<thead>
				<tr class="text-muted-foreground border-b">
					<th scope="col" class="py-1 pr-3">{tx('dms.integrity.col.created')}</th>
					<th scope="col" class="py-1 pr-3">{tx('dms.integrity.col.state')}</th>
					<th scope="col" class="py-1 pr-3">{tx('dms.integrity.col.checked')}</th>
					<th scope="col" class="py-1 pr-3">{tx('dms.integrity.col.bad')}</th>
					<th scope="col" class="py-1 pr-3">{tx('dms.integrity.col.chain')}</th>
					<th scope="col" class="py-1"><span class="sr-only">{tx('dms.actions.title')}</span></th>
				</tr>
			</thead>
			<tbody>
				{#each runs as run (run.id)}
					<tr class="border-b" data-testid="integrity-run" data-state={run.state} aria-current={selected?.id === run.id ? 'true' : undefined}>
						<td class="py-1 pr-3">{when(run.created_at)}</td>
						<td class="py-1 pr-3">{tx(stateText[run.state])}</td>
						<td class="py-1 pr-3">{run.files_checked}</td>
						<td class="py-1 pr-3">{run.files_bad}</td>
						<td class="py-1 pr-3">{chainOk(run)}</td>
						<td class="py-1">
							<Button type="button" size="sm" variant="outline" onclick={() => (selectedId = run.id)} data-testid="integrity-show">{tx('dms.integrity.show')}</Button>
						</td>
					</tr>
				{/each}
			</tbody>
		</table>
	</div>

	{#if selected}
		<section class="mt-5" aria-labelledby="integrity-report-title" data-testid="integrity-report" data-state={selected.state}>
			<h2 id="integrity-report-title" class="mb-2 text-lg font-medium">{tx('dms.integrity.report')}</h2>
			{#if selected.state === 'passed'}
				<div role="status"><Alert.Root><Alert.Description data-testid="integrity-passed">{tx('dms.integrity.passed')}</Alert.Description></Alert.Root></div>
			{:else if selected.state === 'failed' || selected.state === 'error'}
				<div role="alert">
					<Alert.Root variant="destructive">
						<Alert.Title>{tx(stateText[selected.state])}</Alert.Title>
						<Alert.Description data-testid="integrity-failed">
							{selected.state === 'error' ? tx('dms.integrity.errorText', { code: selected.error_code ?? '' }) : tx('dms.integrity.failedText', { bad: selected.files_bad })}
						</Alert.Description>
					</Alert.Root>
				</div>
			{/if}
			<dl class="mt-3 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
				<dt class="text-muted-foreground">{tx('dms.integrity.col.checked')}</dt>
				<dd>{selected.files_checked}</dd>
				<dt class="text-muted-foreground">{tx('dms.integrity.col.bad')}</dt>
				<dd>{selected.files_bad}</dd>
				<dt class="text-muted-foreground">{tx('dms.integrity.started')}</dt>
				<dd>{when(selected.started_at)}</dd>
				<dt class="text-muted-foreground">{tx('dms.integrity.finished')}</dt>
				<dd>{when(selected.finished_at)}</dd>
				{#if selected.report?.chain}
					<dt class="text-muted-foreground">{tx('dms.integrity.chain.entries')}</dt>
					<dd>{selected.report.chain.entries}</dd>
					<dt class="text-muted-foreground">{tx('dms.integrity.col.chain')}</dt>
					<dd data-testid="integrity-chain">
						{#if selected.report.chain.ok}
							{tx('dms.integrity.chain.ok')}
						{:else}
							{selected.report.chain.problem ? tx(chainProblemText[selected.report.chain.problem]) : ''}
							{#if selected.report.chain.broken_at_seq !== null && selected.report.chain.broken_at_seq !== undefined}
								({tx('dms.integrity.chain.brokenAt', { seq: selected.report.chain.broken_at_seq })})
							{/if}
						{/if}
					</dd>
					<dt class="text-muted-foreground">{tx('dms.integrity.headTitle')}</dt>
					<dd class="font-mono text-xs break-all">{selected.report.chain.head}</dd>
				{/if}
			</dl>
			{#if selected.report?.findings && selected.report.findings.length > 0}
				<h3 class="mt-4 mb-1 text-base font-medium">{tx('dms.integrity.findings')}</h3>
				{#if selected.report.truncated}<p class="text-sm" data-testid="integrity-truncated">{tx('dms.integrity.truncated')}</p>{/if}
				<div class="overflow-x-auto">
					<table class="w-full text-left text-sm" data-testid="integrity-findings">
						<caption class="sr-only">{tx('dms.integrity.findings')}</caption>
						<thead>
							<tr class="text-muted-foreground border-b">
								<th scope="col" class="py-1 pr-3">{tx('dms.integrity.f.document')}</th>
								<th scope="col" class="py-1 pr-3">{tx('dms.integrity.f.role')}</th>
								<th scope="col" class="py-1">{tx('dms.integrity.f.problem')}</th>
							</tr>
						</thead>
						<tbody>
							{#each selected.report.findings as f, i (i)}
								<tr class="border-b" data-testid="integrity-finding">
									<td class="py-1 pr-3"><a class="underline-offset-2 hover:underline" href={`/dms/${f.document_id}`}>{f.document_id.slice(0, 8)}</a></td>
									<td class="py-1 pr-3">{f.role}</td>
									<td class="py-1">{tx(problemText[f.problem])}</td>
								</tr>
							{/each}
						</tbody>
					</table>
				</div>
			{/if}
		</section>
	{/if}
{/if}
