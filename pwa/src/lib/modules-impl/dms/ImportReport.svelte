<script lang="ts">
	import { dmsImportApi, type DmsImport, type DmsImportReport } from '#lib/api/client';
	import { i18n, tx } from '#lib/i18n/index.svelte';
	import { importErrorKeys, refParts, reportCounts, reportFindings, reportHasData, stateKeys, targetKeys } from './import';

	let { tenant, run, report }: { tenant: string; run: DmsImport; report: DmsImportReport } = $props();

	const counts = $derived(reportCounts(report));
	const findings = $derived(reportFindings(report));
	const rights = $derived(report.rights as DmsImportReport['rights'] & { visibility_note_code?: string });
	const rules = $derived(report.rule_suggestions ?? []);
	const number = (n: number) => n.toLocaleString(i18n.locale);
	/** A run that read nothing has only its reason to show; archive numbers and owners are only counted up to the end. */
	const read = $derived(reportHasData(report));
	const complete = $derived(report.state === 'done');

	/** "document:7/type:3" becomes "Dokument 7 · Dokumenttyp 3"; unknown shapes stay as the backend wrote them. */
	const refText = (ref: string) =>
		refParts(ref)
			?.map((part) => tx(part.key, { id: part.id }))
			.join(' · ') ?? ref;
</script>

<section class="mt-5 space-y-4" aria-labelledby="import-report-title" data-testid="import-report" data-state={report.state}>
	<div class="flex flex-wrap items-center justify-between gap-3">
		<h2 id="import-report-title" class="panel-title">
			{tx('dms.import.report.title')}: {tx(report.mode === 'dry_run' ? 'dms.import.mode.dry_run' : 'dms.import.mode.import')} · {tx(stateKeys[report.state])}
		</h2>
		<a class="text-sm underline underline-offset-2" href={dmsImportApi.reportUrl(tenant, run.id)} download data-testid="import-download">{tx('dms.import.report.download')}</a>
	</div>

	{#if report.error_code}
		<p class="text-destructive text-sm" data-testid="import-report-error">{tx(importErrorKeys[report.error_code] ?? 'dms.import.error.import_failed')}</p>
	{/if}
	{#if report.state === 'cancelled'}
		<p class="panel text-sm" data-testid="import-cancelled-note">{tx('dms.import.report.cancelledNote')}</p>
	{/if}
	{#if report.mode === 'dry_run'}
		<p class="panel text-sm" data-testid="import-dry-note">{tx('dms.import.report.dryNote')}</p>
	{/if}

	{#if read}
	<div class="panel" data-testid="import-counts">
		<h3 class="mb-2 text-base font-medium">{tx('dms.import.report.counts')}</h3>
		<dl class="grid gap-x-8 gap-y-1 text-sm sm:grid-cols-2">
			{#each counts as count (count.name)}
				<div class="border-border/60 flex items-baseline justify-between gap-3 border-b py-1">
					<dt class="text-muted-foreground min-w-0 break-words">{count.key ? tx(count.key) : count.name}</dt>
					<dd class="font-medium tabular-nums" data-testid={`import-count-${count.name}`}>{number(count.value)}</dd>
				</div>
			{/each}
		</dl>
	</div>

	<div class="panel" data-testid="import-findings">
		<h3 class="mb-2 text-base font-medium">{tx('dms.import.report.findings')}</h3>
		{#if findings.length === 0}
			<p class="text-muted-foreground text-sm" data-testid="import-no-findings">{tx('dms.import.report.noFindings')}</p>
		{:else}
			<ul class="divide-border divide-y">
				{#each findings as finding (finding.code)}
					<li data-testid="import-finding" data-code={finding.code}>
						<details>
							<summary class="focus-visible:ring-ring/50 flex cursor-pointer flex-wrap items-baseline gap-x-3 gap-y-1 rounded py-2 text-sm focus-visible:ring-3">
								<span class="font-medium">{finding.key ? tx(finding.key) : finding.code}</span>
								<span class="tabular-nums">{number(finding.total)}</span>
								<span class={finding.problem ? 'text-destructive text-xs' : 'text-muted-foreground text-xs'}>
									{tx(finding.problem ? 'dms.import.report.problem' : 'dms.import.report.note')}
								</span>
							</summary>
							<ul class="text-muted-foreground mb-2 space-y-0.5 pl-4 text-sm">
								{#each finding.items as item, i (i)}
									<li class="break-words">{refText(item.ref)}{item.detail ? ` – ${item.detail}` : ''}</li>
								{/each}
							</ul>
							{#if finding.total > finding.items.length}
								<p class="text-muted-foreground mb-2 pl-4 text-xs">{tx('dms.import.report.more', { shown: finding.items.length, total: finding.total })}</p>
							{/if}
						</details>
					</li>
				{/each}
			</ul>
		{/if}
	</div>

	{#if complete}
		<div class="panel space-y-2 text-sm" data-testid="import-asn">
			<h3 class="text-base font-medium">{tx('dms.import.report.asn')}</h3>
			<p>{tx('dms.import.report.asnText', { max: report.asn.max_seen, collisions: report.asn.collisions })}</p>
		</div>
	{/if}

	<div class="panel space-y-2 text-sm" data-testid="import-rights">
		<h3 class="text-base font-medium">{tx('dms.import.report.rightsTitle')}</h3>
		<p>{tx('dms.import.report.rights')}</p>
		{#if complete}
			<p class="text-muted-foreground">{tx('dms.import.report.rightsSeen', { owners: rights.owners_seen ?? 0, users: rights.source_users ?? 0, groups: rights.source_groups ?? 0 })}</p>
		{/if}
		<p class="text-muted-foreground" data-testid="import-visibility">
			{tx(report.source_kind === 'api' ? 'dms.import.report.visibilityApi' : 'dms.import.report.visibilityExport')}
		</p>
	</div>
	{/if}

	{#if rules.length > 0}
		<details class="panel text-sm" data-testid="import-rules">
			<summary class="focus-visible:ring-ring/50 cursor-pointer rounded font-medium focus-visible:ring-3">{tx('dms.import.report.rules', { count: rules.length })}</summary>
			<ul class="divide-border mt-2 divide-y">
				{#each rules as rule, i (i)}
					<li class="py-1.5">
						<span class="font-medium">{rule.target_kind ? tx(targetKeys[rule.target_kind], { id: rule.target_name ?? '' }) : rule.target_name}</span>
						<span class="text-muted-foreground block break-words">
							{tx('dms.import.report.ruleAlgorithm')}: {rule.algorithm} · {tx('dms.import.report.ruleMatch')}: <span class="font-mono text-xs">{rule.match}</span>
						</span>
					</li>
				{/each}
			</ul>
		</details>
	{/if}
</section>
