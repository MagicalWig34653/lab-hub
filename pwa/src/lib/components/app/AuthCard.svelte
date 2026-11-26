<script lang="ts">
	import type { Snippet } from 'svelte';
	import * as Card from '#lib/components/ui/card';
	import * as Alert from '#lib/components/ui/alert';
	import Layers from '@lucide/svelte/icons/layers';
	import { t } from '#lib/i18n/index.svelte';

	let {
		title,
		description,
		error = null,
		children
	}: { title: string; description?: string; error?: string | null; children: Snippet } = $props();
</script>

<p class="flex items-center gap-2.5 text-xl font-semibold tracking-tight">
	<span class="bg-background text-ui-accent-ink flex size-10 items-center justify-center rounded-[10px] border" aria-hidden="true">
		<Layers class="size-5" />
	</span>
	{t('app.name')}
</p>

<Card.Root class="w-full max-w-md [--card-spacing:--spacing(6)] md:[--card-spacing:--spacing(7)]">
	<Card.Header>
		<Card.Title><h1 class="text-[21px] font-semibold tracking-tight">{title}</h1></Card.Title>
		{#if description}<Card.Description>{description}</Card.Description>{/if}
	</Card.Header>
	<Card.Content class="space-y-4">
		{#if error}
			<div role="alert" data-testid="form-error">
				<Alert.Root variant="destructive"><Alert.Description>{error}</Alert.Description></Alert.Root>
			</div>
		{/if}
		{@render children()}
	</Card.Content>
</Card.Root>
