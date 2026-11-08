<script lang="ts">
	import DmsPage from '#lib/modules-impl/dms/DmsPage.svelte';
	import { P } from '#lib/modules-impl/dms/permissions';
	import TrashPage from '#lib/modules-impl/dms/TrashPage.svelte';
</script>

<DmsPage permission={P.documentTrash} title="dms.nav.trash">
	{#snippet children(tenant)}<TrashPage {tenant} />{/snippet}
</DmsPage>
