<script lang="ts">
	import DmsPage from '#lib/modules-impl/dms/DmsPage.svelte';
	import { P } from '#lib/modules-impl/dms/permissions';
	import ReviewQueue from '#lib/modules-impl/dms/ReviewQueue.svelte';
</script>

<DmsPage permission={P.suggestionRead} title="dms.nav.review">
	{#snippet children(tenant)}<ReviewQueue {tenant} />{/snippet}
</DmsPage>
