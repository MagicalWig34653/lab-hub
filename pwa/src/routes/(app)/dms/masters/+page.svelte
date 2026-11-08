<script lang="ts">
	import DmsPage from '#lib/modules-impl/dms/DmsPage.svelte';
	import MastersPage from '#lib/modules-impl/dms/MastersPage.svelte';
</script>

<DmsPage permission="dms.document.read" title="dms.nav.masters">
	{#snippet children(tenant)}<MastersPage {tenant} />{/snippet}
</DmsPage>
