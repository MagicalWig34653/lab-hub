<script lang="ts">
	import DmsPage from '#lib/modules-impl/dms/DmsPage.svelte';
	import ExportsPage from '#lib/modules-impl/dms/ExportsPage.svelte';
	import { P } from '#lib/modules-impl/dms/permissions';
</script>

<DmsPage permission={P.exportRun} title="dms.nav.exports">
	{#snippet children(tenant)}<ExportsPage {tenant} />{/snippet}
</DmsPage>
