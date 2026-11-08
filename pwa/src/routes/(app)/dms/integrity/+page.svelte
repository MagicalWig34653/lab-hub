<script lang="ts">
	import DmsPage from '#lib/modules-impl/dms/DmsPage.svelte';
	import IntegrityPage from '#lib/modules-impl/dms/IntegrityPage.svelte';
	import { P } from '#lib/modules-impl/dms/permissions';
</script>

<DmsPage permission={P.integrityRun} title="dms.nav.integrity">
	{#snippet children(tenant)}<IntegrityPage {tenant} />{/snippet}
</DmsPage>
