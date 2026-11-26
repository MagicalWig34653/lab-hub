<script lang="ts">
	import { page } from '$app/state';
	import PageHeader from '#lib/components/app/PageHeader.svelte';
	import { t, type MessageKey } from '#lib/i18n/index.svelte';

	let { children } = $props();

	const PAGES = ['profile', 'appearance', 'security', 'sessions', 'modules', 'members'];
	const current = $derived(PAGES.find((name) => page.url.pathname.startsWith(`/settings/${name}`)));
</script>

<!-- The settings pages are listed in the sidebar group "Einstellungen" (WP-F4c). -->
{#if current}
	<PageHeader title={t(`settings.${current}` as MessageKey)} lead={t(`settings.lead.${current}` as MessageKey)} />
{:else}
	<PageHeader title={t('settings.title')} />
{/if}
{@render children()}
