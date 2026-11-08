<script lang="ts">
	import type { DmsSuggestion } from '#lib/api/client';
	import { Button } from '#lib/components/ui/button';
	import { i18n, tx } from '#lib/i18n/index.svelte';
	import type { Masters } from './masters';
	import { KIND_TEXT, suggestionValueText } from './suggestion';

	let {
		suggestion,
		masters,
		ruleName = null,
		stale = false,
		decided = null,
		canDecide,
		busy = false,
		showDocument = true,
		tabbable = true,
		onaccept,
		onreject
	}: {
		suggestion: DmsSuggestion;
		masters: Masters;
		ruleName?: string | null;
		stale?: boolean;
		decided?: 'accepted' | 'rejected' | null;
		canDecide: boolean;
		busy?: boolean;
		showDocument?: boolean;
		/** Roving tabindex: only the active row of a list is a tab stop. */
		tabbable?: boolean;
		onaccept: () => void;
		onreject: () => void;
	} = $props();

	const value = $derived(suggestionValueText(suggestion, masters, i18n.locale));
	const percent = $derived(Math.round(suggestion.confidence * 100));
</script>

<div class="flex flex-wrap items-start justify-between gap-3" data-testid="suggestion-card">
	<div class="min-w-0 flex-1 space-y-1">
		<p class="text-sm">
			{#if showDocument}
				<a href={`/dms/${suggestion.document_id}`} class="font-medium underline-offset-2 hover:underline" tabindex={tabbable ? 0 : -1} data-row-link data-testid="suggestion-document">{suggestion.document_title}</a>
				<span class="text-muted-foreground" aria-hidden="true">·</span>
			{/if}
			<span class="text-muted-foreground">{tx(KIND_TEXT[suggestion.kind])}:</span>
			<strong class="break-words" data-testid="suggestion-value">{value}</strong>
		</p>
		<p class="text-muted-foreground text-xs" data-testid="suggestion-reason">
			{tx('dms.suggestion.reason')}: {suggestion.reason}
		</p>
		<p class="text-muted-foreground text-xs">
			{tx('dms.suggestion.confidence', { percent })}
			{#if suggestion.source === 'contact_match'}· {tx('dms.suggestion.source.contact')}{:else if ruleName}· {tx('dms.suggestion.source.rule', { name: ruleName })}{/if}
		</p>
		{#if stale}
			<p class="text-destructive text-xs" role="status" data-testid="suggestion-stale">{tx('dms.suggestion.stale')}</p>
		{/if}
		{#if decided}
			<p class="text-xs" role="status" data-testid="suggestion-decided">{tx(decided === 'accepted' ? 'dms.suggestion.decided.accepted' : 'dms.suggestion.decided.rejected')}</p>
		{/if}
	</div>
	{#if canDecide && !decided}
		<div class="flex flex-wrap gap-2">
			<Button type="button" size="sm" disabled={busy || stale} tabindex={tabbable ? 0 : -1} onclick={onaccept} data-testid="suggestion-accept" aria-keyshortcuts="A">
				{tx('dms.suggestion.accept')}
			</Button>
			<Button type="button" size="sm" variant="outline" disabled={busy} tabindex={tabbable ? 0 : -1} onclick={onreject} data-testid="suggestion-reject" aria-keyshortcuts="R">
				{tx('dms.suggestion.reject')}
			</Button>
			{#if showDocument}
				<a
					href={`/dms/${suggestion.document_id}`}
					class="border-border bg-background hover:bg-muted focus-visible:ring-ring/50 inline-flex h-7 items-center rounded-lg border px-2.5 text-[0.8rem] font-medium focus-visible:ring-3"
					tabindex={tabbable ? 0 : -1}
					data-testid="suggestion-change"
					aria-keyshortcuts="E"
				>
					{tx('dms.suggestion.change')}
				</a>
			{/if}
		</div>
	{/if}
</div>
