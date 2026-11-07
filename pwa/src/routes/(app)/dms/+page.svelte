<script lang="ts">
	import ModuleGate from '#lib/components/app/ModuleGate.svelte';
	import { t, tx } from '#lib/i18n/index.svelte';
</script>

<svelte:head><title>{tx('nav.dms')} · {t('app.name')}</title></svelte:head>

<!-- Placeholder (WP-F2): the DMS UI (WP-F4) replaces this page and adds its routes below /dms. -->
<ModuleGate moduleKey="dms">
	<h1 class="mb-2 text-2xl font-semibold" data-testid="dms-placeholder">{tx('dms.placeholder.title')}</h1>
	<p class="text-muted-foreground">{tx('dms.placeholder.text')}</p>
</ModuleGate>
