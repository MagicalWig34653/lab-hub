<script lang="ts">
	import { t } from '#lib/i18n/index.svelte';

	let { children } = $props();
</script>

<!-- The settings pages are listed in the sidebar group "Einstellungen" (WP-F4c). -->
<div class="mb-7">
	<h1 class="page-title">{t('settings.title')}</h1>
	<p class="text-muted-foreground mt-1">{t('settings.subtitle')}</p>
</div>
{@render children()}
