<script lang="ts">
	import LanguageSwitch from '#lib/components/app/LanguageSwitch.svelte';

	let { children } = $props();
</script>

<main class="bg-sidebar flex min-h-dvh flex-col items-center justify-center gap-6 p-4">
	{@render children()}
	<LanguageSwitch />
</main>
