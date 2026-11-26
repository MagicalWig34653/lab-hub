<script lang="ts">
	import type { Snippet } from 'svelte';

	/** Page head (TimeTrack "pagehead"): title, one explaining line, the main action on the right (stacked on a phone). */
	let {
		title,
		lead,
		testid,
		actions,
		children
	}: { title: string; lead?: string; testid?: string; actions?: Snippet; children?: Snippet } = $props();
</script>

<div class="mb-7 flex flex-wrap items-end justify-between gap-3 min-[761px]:mb-8">
	<div class="min-w-0 max-w-[820px]">
		<h1 class="page-title" data-testid={testid}>{title}</h1>
		{#if lead}<p class="page-lead" data-testid="page-lead">{lead}</p>{/if}
		{@render children?.()}
	</div>
	{#if actions}<div class="page-actions flex flex-wrap items-center gap-2">{@render actions()}</div>{/if}
</div>
