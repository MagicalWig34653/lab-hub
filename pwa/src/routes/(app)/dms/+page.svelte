<script lang="ts">
	import ModuleGate from '#lib/components/app/ModuleGate.svelte';
	import { t, tx } from '#lib/i18n/index.svelte';
	import DmsBrowser from '#lib/modules-impl/dms/DmsBrowser.svelte';
	import { workspace } from '#lib/workspace.svelte';
</script>

<svelte:head><title>{tx('nav.dms')} · {t('app.name')}</title></svelte:head>

<ModuleGate moduleKey="dms">
	{#if workspace.activeId}
		{#if workspace.can('dms.document.read')}
			<DmsBrowser tenant={workspace.activeId} />
		{:else}
			<p class="text-muted-foreground" data-testid="dms-forbidden">{tx('dms.noPermission')}</p>
		{/if}
	{/if}
</ModuleGate>
