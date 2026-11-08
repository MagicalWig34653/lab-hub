<script lang="ts">
	import DuplicatesPage from '#lib/modules-impl/dms/DuplicatesPage.svelte';
	import DmsPage from '#lib/modules-impl/dms/DmsPage.svelte';
</script>

<DmsPage permission="dms.document.read" title="dms.nav.duplicates">
	{#snippet children(tenant)}<DuplicatesPage {tenant} />{/snippet}
</DmsPage>
