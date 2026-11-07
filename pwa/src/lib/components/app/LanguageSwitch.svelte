<script lang="ts">
	import { i18n, locales, t, type Locale } from '#lib/i18n/index.svelte';

	function onchange(event: Event) {
		i18n.set((event.currentTarget as HTMLSelectElement).value as Locale);
	}
</script>

<label class="text-muted-foreground flex items-center gap-2 text-sm">
	<span>{t('common.language')}</span>
	<select
		class="border-input bg-background h-8 rounded-md border px-2 text-sm"
		value={i18n.locale}
		{onchange}
		data-testid="language-switch"
	>
		{#each locales as locale (locale)}
			<option value={locale}>{t(`common.language.${locale}`)}</option>
		{/each}
	</select>
</label>
