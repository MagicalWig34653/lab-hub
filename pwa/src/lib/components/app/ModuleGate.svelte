<script lang="ts">
	import type { Snippet } from 'svelte';
	import * as Alert from '#lib/components/ui/alert';
	import { t } from '#lib/i18n/index.svelte';
	import { workspace } from '#lib/workspace.svelte';

	let { moduleKey, children }: { moduleKey: string; children: Snippet } = $props();
</script>

<!-- A route of a module that is not effective in the active tenant shows ModuleDisabled (backend: 404 module_disabled). -->
{#if workspace.loading || !workspace.modules}
	<p class="text-muted-foreground text-sm">{t('common.loading')}</p>
{:else if workspace.moduleEffective(moduleKey)}
	{@render children()}
{:else}
	<div data-testid="module-disabled">
		<Alert.Root>
			<Alert.Title>{t('module.disabled.title')}</Alert.Title>
			<Alert.Description>{t('module.disabled.text')}</Alert.Description>
		</Alert.Root>
	</div>
{/if}
