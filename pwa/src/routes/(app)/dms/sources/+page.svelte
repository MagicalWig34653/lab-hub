<script lang="ts">
	import DmsPage from '#lib/modules-impl/dms/DmsPage.svelte';
	import { P } from '#lib/modules-impl/dms/permissions';
	import SourcesPage from '#lib/modules-impl/dms/SourcesPage.svelte';
</script>

<DmsPage permission={P.sourceRead} title="dms.nav.sources">
	{#snippet children(tenant)}<SourcesPage {tenant} />{/snippet}
</DmsPage>
