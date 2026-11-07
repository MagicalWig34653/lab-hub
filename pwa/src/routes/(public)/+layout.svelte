<script lang="ts">
	import LanguageSwitch from '#lib/components/app/LanguageSwitch.svelte';

	let { children } = $props();
</script>

<main class="flex min-h-screen flex-col items-center justify-center gap-6 p-4">
	{@render children()}
	<LanguageSwitch />
</main>
