<script lang="ts">
	import './layout.css';
	import { i18n } from '#lib/i18n/index.svelte';

	let { children } = $props();

	$effect(() => {
		document.documentElement.lang = i18n.locale;
	});
</script>

{@render children()}
