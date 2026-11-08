<script lang="ts">
	import type { Snippet } from 'svelte';
	import ModuleGate from '#lib/components/app/ModuleGate.svelte';
	import { t, tx } from '#lib/i18n/index.svelte';
	import { workspace } from '#lib/workspace.svelte';

	/** Frame of a DMS sub page: module gate, tab title, permission check (visibility only; the backend authorizes). */
	let { permission, title, children }: { permission: string; title: string; children: Snippet<[string]> } = $props();
</script>

<svelte:head><title>{tx(title)} · {tx('nav.dms')} · {t('app.name')}</title></svelte:head>

<ModuleGate moduleKey="dms">
	{#if workspace.activeId}
		{#if workspace.can(permission)}
			{@render children(workspace.activeId)}
		{:else}
			<p class="text-muted-foreground" data-testid="dms-forbidden">{tx('dms.noPermissionHere')}</p>
		{/if}
	{/if}
</ModuleGate>
