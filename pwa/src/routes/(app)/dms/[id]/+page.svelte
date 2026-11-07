<script lang="ts">
	import { page } from '$app/state';
	import ModuleGate from '#lib/components/app/ModuleGate.svelte';
	import { t, tx } from '#lib/i18n/index.svelte';
	import DocumentDetail from '#lib/modules-impl/dms/DocumentDetail.svelte';
	import { workspace } from '#lib/workspace.svelte';
</script>

<svelte:head><title>{tx('nav.dms')} · {t('app.name')}</title></svelte:head>

<ModuleGate moduleKey="dms">
	{#if workspace.activeId}
		{#if workspace.can('dms.document.read')}
			{#key page.params.id}
				<DocumentDetail tenant={workspace.activeId} id={page.params.id ?? ''} />
			{/key}
		{:else}
			<p class="text-muted-foreground" data-testid="dms-forbidden">{tx('dms.noPermission')}</p>
		{/if}
	{/if}
</ModuleGate>
