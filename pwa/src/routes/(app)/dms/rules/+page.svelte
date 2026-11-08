<script lang="ts">
	import DmsPage from '#lib/modules-impl/dms/DmsPage.svelte';
	import { P } from '#lib/modules-impl/dms/permissions';
	import RulesPage from '#lib/modules-impl/dms/RulesPage.svelte';
</script>

<DmsPage permission={P.ruleRead} title="dms.nav.rules">
	{#snippet children(tenant)}<RulesPage {tenant} />{/snippet}
</DmsPage>
