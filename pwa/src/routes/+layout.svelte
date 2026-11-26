<script lang="ts">
	import './layout.css';
	import { onMount } from 'svelte';
	import { theme } from '#lib/theme/theme.svelte';
	import { i18n } from '#lib/i18n/index.svelte';

	let { children } = $props();

	onMount(() => theme.init());

	$effect(() => {
		document.documentElement.lang = i18n.locale;
	});
</script>

{@render children()}
