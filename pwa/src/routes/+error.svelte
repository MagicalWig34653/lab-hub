<script lang="ts">
	import { page } from '$app/state';
	import { errorMessage, t } from '#lib/i18n/index.svelte';
	import { ApiError } from '#lib/api/errors';

	// load() errors from the guard arrive as plain SvelteKit errors; map status to the text catalogue.
	const message = $derived(
		page.error instanceof ApiError ? errorMessage(page.error) : t('error.generic')
	);
</script>

<main class="flex min-h-screen flex-col items-center justify-center gap-2 p-4" role="alert">
	<p class="text-muted-foreground text-sm">{page.status}</p>
	<p>{message}</p>
</main>
