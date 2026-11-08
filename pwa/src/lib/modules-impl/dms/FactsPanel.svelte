<script lang="ts">
	import { ApiError, dmsApi, type DmsExtraction } from '#lib/api/client';
	import ErrorBanner from '#lib/components/app/ErrorBanner.svelte';
	import { Button } from '#lib/components/ui/button';
	import { formatDate } from '#lib/format';
	import { errorMessage, i18n, tx } from '#lib/i18n/index.svelte';
	import KindBadge from './KindBadge.svelte';
	import { AMOUNT_FACTS, DATE_FACTS, FACT_LABEL, formatMoney } from './overview';

	/**
	 * Recognised document kind and facts of one document (WP-D7 routes). Each fact shows value, confidence, the reason and the
	 * passage it was found in (as text). Candidates for document fields are accepted or rejected in the suggestion list next to it.
	 */
	let {
		tenant,
		documentId,
		canRerun,
		onrerun
	}: { tenant: string; documentId: string; canRerun: boolean; onrerun: () => void } = $props();
	// svelte-ignore state_referenced_locally
	const tenantId = tenant;
	// svelte-ignore state_referenced_locally
	const docId = documentId;

	let extraction = $state<DmsExtraction | null>(null);
	let loaded = $state(false);
	let error = $state<string | null>(null);
	let running = $state(false);

	async function load() {
		try {
			extraction = await dmsApi.extraction(tenantId, docId);
		} catch (e) {
			// 404: nothing recognised yet (still processing, or no text); everything else is shown
			if (!(e instanceof ApiError && e.status === 404)) error = errorMessage(e);
		} finally {
			loaded = true;
		}
	}
	void load();

	async function rerun() {
		running = true;
		error = null;
		try {
			extraction = await dmsApi.runExtraction(tenantId, docId);
			onrerun();
		} catch (e) {
			error = errorMessage(e);
		} finally {
			running = false;
		}
	}

	const valueText = (type: string, value: string, currency?: string | null) =>
		AMOUNT_FACTS.has(type) ? formatMoney(value, currency, i18n.locale) : DATE_FACTS.has(type) ? formatDate(value, i18n.locale) || value : value;
	const labelOf = (type: string) => (type in FACT_LABEL ? tx(FACT_LABEL[type as keyof typeof FACT_LABEL]) : type);
</script>

<section class="mt-8" aria-labelledby="dms-facts-title" data-testid="dms-facts">
	<div class="mb-2 flex flex-wrap items-center justify-between gap-2">
		<h2 id="dms-facts-title" class="text-lg font-medium">{tx('dms.facts.title')}</h2>
		{#if canRerun}
			<Button type="button" size="sm" variant="outline" disabled={running} onclick={rerun} data-testid="dms-extraction-rerun">{tx('dms.facts.rerun')}</Button>
		{/if}
	</div>
	<ErrorBanner message={error} />
	{#if !loaded}
		<p class="text-muted-foreground text-sm">{tx('common.loading')}</p>
	{:else if !extraction}
		<p class="text-muted-foreground text-sm" data-testid="dms-facts-none">{tx('dms.facts.none')}</p>
	{:else}
		<p class="mb-2 flex flex-wrap items-center gap-2 text-sm">
			<KindBadge kind={extraction.kind} certain={extraction.kind_certain} />
			<span class="text-muted-foreground text-xs" data-testid="dms-facts-score">{tx('dms.facts.score', { percent: Math.round(extraction.kind_score * 100) })}</span>
			{#if !extraction.kind_certain}<span class="text-xs" data-testid="dms-facts-uncertain">{tx('dms.kind.uncertain')}</span>{/if}
		</p>
		{#if extraction.reasons && extraction.reasons.length > 0}
			<ul class="text-muted-foreground mb-3 list-disc pl-5 text-xs" data-testid="dms-facts-reasons">
				{#each extraction.reasons as reason, i (i)}<li>{reason}</li>{/each}
			</ul>
		{/if}
		{#if (extraction.facts ?? []).length === 0}
			<p class="text-muted-foreground text-sm">{tx('dms.facts.noFacts')}</p>
		{:else}
			<ul class="divide-y rounded-md border">
				{#each extraction.facts ?? [] as fact, i (i)}
					<li class="p-3" data-testid="dms-fact" data-type={fact.type}>
						<div class="flex flex-wrap items-baseline justify-between gap-x-3">
							<span class="text-muted-foreground text-sm">{labelOf(fact.type)}</span>
							<strong class="text-sm break-all tabular-nums" data-testid="dms-fact-value">{valueText(fact.type, fact.value, fact.currency)}</strong>
						</div>
						<p class="text-muted-foreground mt-0.5 text-xs">{tx('dms.suggestion.confidence', { percent: Math.round(fact.confidence * 100) })} · {fact.reason}</p>
						{#if fact.source}
							<!-- The passage is inserted as text, never as HTML. -->
							<p class="text-muted-foreground mt-0.5 text-xs break-words" data-testid="dms-fact-source">{tx('dms.facts.foundAt')}: <q>{fact.source.excerpt}</q></p>
						{/if}
					</li>
				{/each}
			</ul>
		{/if}
	{/if}
</section>
