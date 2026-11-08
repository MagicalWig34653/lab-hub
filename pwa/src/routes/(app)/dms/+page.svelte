<script lang="ts">
	import ModuleGate from '#lib/components/app/ModuleGate.svelte';
	import { t, tx } from '#lib/i18n/index.svelte';
	import DocumentOverview from '#lib/modules-impl/dms/DocumentOverview.svelte';
	import { workspace } from '#lib/workspace.svelte';
</script>

<svelte:head><title>{tx('nav.dms')} · {t('app.name')}</title></svelte:head>

<ModuleGate moduleKey="dms">
	{#if workspace.activeId}
		{#if workspace.can('dms.document.read')}
			<DocumentOverview tenant={workspace.activeId} />
		{:else}
			<p class="text-muted-foreground" data-testid="dms-forbidden">{tx('dms.noPermission')}</p>
		{/if}
	{/if}
</ModuleGate>
