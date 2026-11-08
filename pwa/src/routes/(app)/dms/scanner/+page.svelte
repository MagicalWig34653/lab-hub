<script lang="ts">
	import DmsPage from '#lib/modules-impl/dms/DmsPage.svelte';
	import { P } from '#lib/modules-impl/dms/permissions';
	import ScannerPage from '#lib/modules-impl/dms/ScannerPage.svelte';
</script>

<DmsPage permission={P.documentCreate} title="dms.nav.scanner">
	{#snippet children(tenant)}<ScannerPage {tenant} />{/snippet}
</DmsPage>
