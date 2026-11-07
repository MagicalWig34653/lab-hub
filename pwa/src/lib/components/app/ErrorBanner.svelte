<script lang="ts">
	import * as Alert from '#lib/components/ui/alert';

	let { message }: { message: string | null } = $props();
</script>

{#if message}
	<div role="alert" class="mb-4" data-testid="error-banner">
		<Alert.Root variant="destructive"><Alert.Description>{message}</Alert.Description></Alert.Root>
	</div>
{/if}
