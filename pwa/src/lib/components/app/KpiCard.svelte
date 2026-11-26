<script lang="ts">
	import type { Component } from 'svelte';
	import type { IconProps } from '#lib/modules/manifest';

	let { label, value, hint, icon: Icon, testid }: { label: string; value: string; hint?: string; icon: Component<IconProps>; testid?: string } = $props();
</script>

<!-- KPI card (TimeTrack pattern): title and symbol, large number, explanation. -->
<div class="bg-card min-w-0 rounded-[10px] border p-4 shadow-(--shadow-card) md:p-5" data-testid={testid}>
	<div class="text-muted-foreground flex items-start justify-between gap-2 text-sm font-medium">
		<span class="min-w-0 break-words">{label}</span>
		<Icon class="mt-0.5 size-4 shrink-0" aria-hidden="true" />
	</div>
	<p class="mt-1.5 break-words {value.length > 8 ? 'text-2xl leading-[39px] font-semibold tracking-tight' : 'kpi-value'}">{value}</p>
	{#if hint}<p class="text-muted-foreground text-[13px] leading-snug">{hint}</p>{/if}
</div>
