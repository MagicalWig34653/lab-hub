<script lang="ts">
	import DmsNav from '#lib/modules-impl/dms/DmsNav.svelte';

	let { children } = $props();
</script>

<DmsNav />
{@render children()}
