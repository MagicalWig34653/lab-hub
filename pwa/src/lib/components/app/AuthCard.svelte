<script lang="ts">
	import type { Snippet } from 'svelte';
	import * as Card from '#lib/components/ui/card';
	import * as Alert from '#lib/components/ui/alert';

	let {
		title,
		description,
		error = null,
		children
	}: { title: string; description?: string; error?: string | null; children: Snippet } = $props();
</script>

<Card.Root class="w-full max-w-md">
	<Card.Header>
		<Card.Title><h1 class="text-xl font-semibold">{title}</h1></Card.Title>
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
