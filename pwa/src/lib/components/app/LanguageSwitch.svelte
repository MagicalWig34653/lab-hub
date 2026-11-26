<script lang="ts">
	import { i18n, locales, t, type Locale } from '#lib/i18n/index.svelte';

	/** compact: the label is only for screen readers (header) */
	let { compact = false }: { compact?: boolean } = $props();

	function onchange(event: Event) {
		i18n.set((event.currentTarget as HTMLSelectElement).value as Locale);
	}
</script>

<label class="text-muted-foreground flex items-center gap-2 text-sm">
	<span class={compact ? 'sr-only' : ''}>{t('common.language')}</span>
	<select
		class="border-input bg-background text-foreground h-9 rounded-lg border px-2 text-sm"
		value={i18n.locale}
		{onchange}
		data-testid="language-switch"
	>
		{#each locales as locale (locale)}
			<option value={locale}>{t(`common.language.${locale}`)}</option>
		{/each}
	</select>
</label>
