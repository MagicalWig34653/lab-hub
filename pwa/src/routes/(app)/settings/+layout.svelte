<script lang="ts">
	import { t } from '#lib/i18n/index.svelte';

	let { children } = $props();
</script>

<!-- The settings pages are listed in the sidebar group "Einstellungen" (WP-F4c). -->
<h1 class="mb-6 text-[28px] leading-tight font-[650] tracking-[-0.8px]">{t('settings.title')}</h1>
{@render children()}
