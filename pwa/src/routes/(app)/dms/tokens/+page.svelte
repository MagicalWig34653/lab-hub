<script lang="ts">
	import DmsPage from '#lib/modules-impl/dms/DmsPage.svelte';
	import { P } from '#lib/modules-impl/dms/permissions';
	import TokensPage from '#lib/modules-impl/dms/TokensPage.svelte';
</script>

<DmsPage permission={P.documentCreate} title="dms.nav.tokens">
	{#snippet children()}<TokensPage />{/snippet}
</DmsPage>
