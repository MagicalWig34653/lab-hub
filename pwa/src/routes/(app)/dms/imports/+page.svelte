<script lang="ts">
	import DmsPage from '#lib/modules-impl/dms/DmsPage.svelte';
	import ImportPage from '#lib/modules-impl/dms/ImportPage.svelte';
	import { P } from '#lib/modules-impl/dms/permissions';
</script>

<DmsPage permission={P.importRead} title="dms.nav.imports">
	{#snippet children(tenant)}<ImportPage {tenant} />{/snippet}
</DmsPage>
