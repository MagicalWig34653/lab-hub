<script lang="ts">
	import type { DmsDocumentKind } from '#lib/api/client';
	import { tx } from '#lib/i18n/index.svelte';
	import { KIND_LABEL } from './overview';

	/** Badge for the document kind of the extractor. An uncertain kind (score below the certainty threshold) gets a "?" and a spoken hint. */
	let { kind, certain = true }: { kind: DmsDocumentKind; certain?: boolean } = $props();

	const tone: Partial<Record<DmsDocumentKind, string>> = {
		invoice: 'bg-blue-100 text-blue-900 dark:bg-blue-950 dark:text-blue-100',
		reminder: 'bg-red-100 text-red-900 dark:bg-red-950 dark:text-red-100',
		receipt: 'bg-emerald-100 text-emerald-900 dark:bg-emerald-950 dark:text-emerald-100',
		tax_notice: 'bg-amber-100 text-amber-900 dark:bg-amber-950 dark:text-amber-100'
	};
</script>

<span
	class="inline-flex items-center gap-0.5 rounded-md px-1.5 py-0.5 text-xs font-medium whitespace-nowrap {tone[kind] ?? 'bg-secondary text-secondary-foreground'}"
	data-testid="kind-badge"
	data-kind={kind}
>
	{tx(KIND_LABEL[kind])}{#if !certain}<span aria-hidden="true">?</span><span class="sr-only"> ({tx('dms.kind.uncertain')})</span>{/if}
</span>
