<script lang="ts">
	import DmsPage from '#lib/modules-impl/dms/DmsPage.svelte';
	import InboxPage from '#lib/modules-impl/dms/InboxPage.svelte';
</script>

<DmsPage permission="dms.document.read" title="dms.nav.inbox">
	{#snippet children(tenant)}<InboxPage {tenant} />{/snippet}
</DmsPage>
