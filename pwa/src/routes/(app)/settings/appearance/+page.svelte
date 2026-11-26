<script lang="ts">
	import Check from '@lucide/svelte/icons/check';
	import Monitor from '@lucide/svelte/icons/monitor';
	import Moon from '@lucide/svelte/icons/moon';
	import Sun from '@lucide/svelte/icons/sun';
	import LanguageSwitch from '#lib/components/app/LanguageSwitch.svelte';
	import * as Alert from '#lib/components/ui/alert';
	import * as Card from '#lib/components/ui/card';
	import { Button } from '#lib/components/ui/button';
	import { Input } from '#lib/components/ui/input';
	import { errorMessage, t, type MessageKey } from '#lib/i18n/index.svelte';
	import { ACCENT_PRESETS, accentTokens, normalizeHex } from '#lib/theme/accent';
	import { theme, type ThemeMode } from '#lib/theme/theme.svelte';

	const modes = [
		{ id: 'system', icon: Monitor },
		{ id: 'light', icon: Sun },
		{ id: 'dark', icon: Moon }
	] as const;

	let error = $state<string | null>(null);
	let status = $state('');
	let pending = $state(false);
	let draft = $state<string | null>(null);

	const custom = $derived(draft ?? theme.accent);
	const selectedPreset = $derived(ACCENT_PRESETS.find((p) => p.hex === theme.accent)?.id ?? null);

	async function save(colour: string | null) {
		pending = true;
		error = null;
		status = '';
		try {
			await theme.setAccent(colour);
			draft = null;
			status = t('appearance.accent.saved');
		} catch (e) {
			error = errorMessage(e);
		} finally {
			pending = false;
		}
	}

	function applyCustom(event: SubmitEvent) {
		event.preventDefault();
		const hex = normalizeHex(custom);
		if (!hex) {
			error = t('appearance.accent.invalid');
			return;
		}
		void save(hex);
	}

	/** Arrow keys move inside a radio group (focus follows, space/enter chooses). */
	function radioKeys(event: KeyboardEvent) {
		const step = ['ArrowRight', 'ArrowDown'].includes(event.key) ? 1 : ['ArrowLeft', 'ArrowUp'].includes(event.key) ? -1 : 0;
		if (!step) return;
		const items = [...(event.currentTarget as HTMLElement).querySelectorAll<HTMLElement>('[role="radio"]')];
		const index = items.indexOf(document.activeElement as HTMLElement);
		if (index < 0) return;
		event.preventDefault();
		items[(index + step + items.length) % items.length].focus();
	}

	/** The check mark on a swatch: white or black, whichever is readable on the preset colour itself. */
	const swatchMark = (hex: string) => (accentTokens(hex, false)?.foreground ?? '#ffffff');
</script>

<svelte:head><title>{t('settings.appearance')} · {t('app.name')}</title></svelte:head>

<div class="max-w-[820px] space-y-5">
	{#if error}
		<div role="alert" data-testid="appearance-error">
			<Alert.Root variant="destructive"><Alert.Description>{error}</Alert.Description></Alert.Root>
		</div>
	{/if}

	<Card.Root>
		<Card.Header>
			<Card.Title><h2 class="panel-title">{t('appearance.mode.title')}</h2></Card.Title>
			<Card.Description>{t('appearance.mode.help')}</Card.Description>
		</Card.Header>
		<Card.Content>
			<!-- svelte-ignore a11y_interactive_supports_focus -->
			<div role="radiogroup" aria-label={t('appearance.mode.title')} class="bg-muted inline-flex w-full gap-1 rounded-xl p-1 sm:w-auto" onkeydown={radioKeys}>
				{#each modes as mode (mode.id)}
					{@const Icon = mode.icon}
					{@const checked = theme.mode === mode.id}
					<button
						type="button"
						role="radio"
						aria-checked={checked}
						class="flex h-10 flex-1 items-center justify-center gap-2 rounded-lg px-4 text-sm font-medium sm:flex-none {checked ? 'bg-background text-foreground shadow-sm' : 'text-muted-foreground hover:text-foreground'}"
						onclick={() => theme.setMode(mode.id as ThemeMode)}
						data-testid={`theme-${mode.id}`}
					>
						<Icon class="size-4" aria-hidden="true" />
						{t(`appearance.mode.${mode.id}` as MessageKey)}
					</button>
				{/each}
			</div>
		</Card.Content>
	</Card.Root>

	<Card.Root>
		<Card.Header>
			<Card.Title><h2 class="panel-title">{t('appearance.accent.title')}</h2></Card.Title>
			<Card.Description>{t('appearance.accent.help')}</Card.Description>
		</Card.Header>
		<Card.Content class="space-y-5">
			<!-- svelte-ignore a11y_interactive_supports_focus -->
			<div role="radiogroup" aria-label={t('appearance.accent.presets')} class="grid grid-cols-[repeat(auto-fill,minmax(5.25rem,1fr))] gap-2" onkeydown={radioKeys}>
				{#each ACCENT_PRESETS as preset (preset.id)}
					{@const checked = selectedPreset === preset.id}
					<button
						type="button"
						role="radio"
						aria-checked={checked}
						disabled={pending}
						class="flex flex-col items-center gap-1.5 rounded-lg border px-1 py-2.5 text-xs font-medium {checked ? 'bg-ui-accent-soft text-ui-accent-ink border-ui-accent' : 'text-muted-foreground hover:bg-muted'}"
						onclick={() => save(preset.hex)}
						data-testid={`accent-${preset.id}`}
					>
						<span class="ring-foreground/25 flex size-8 items-center justify-center rounded-full ring-1" style="background: {preset.hex}; color: {swatchMark(preset.hex)}" aria-hidden="true">
							{#if checked}<Check class="size-4" />{/if}
						</span>
						{t(`appearance.accent.color.${preset.id}` as MessageKey)}
					</button>
				{/each}
			</div>

			<form class="flex flex-wrap items-end gap-2" onsubmit={applyCustom}>
				<label class="flex flex-col gap-1.5 text-sm font-medium">
					{t('appearance.accent.custom')}
					<span class="flex items-center gap-2">
						<input
							type="color"
							class="border-input bg-background size-10 shrink-0 rounded-lg border p-1"
							aria-label={t('appearance.accent.custom')}
							value={normalizeHex(custom) ?? theme.accent}
							oninput={(event) => (draft = event.currentTarget.value)}
							data-testid="accent-picker"
						/>
						<Input class="w-32 font-mono" value={custom} oninput={(event) => (draft = event.currentTarget.value)} maxlength={7} spellcheck="false" data-testid="accent-custom" />
					</span>
				</label>
				<Button type="submit" disabled={pending} data-testid="accent-custom-apply">{t('appearance.accent.apply')}</Button>
				<Button type="button" variant="outline" disabled={pending || theme.isDefault} onclick={() => save(null)} data-testid="accent-reset">
					{t('appearance.accent.reset')}
				</Button>
			</form>
			<p class="{status ? 'text-muted-foreground text-sm' : 'sr-only'}" role="status" data-testid="accent-status">{status}</p>

			<div class="rounded-lg border p-4">
				<p class="text-muted-foreground mb-3 text-[11px] font-semibold tracking-[0.06em] uppercase">{t('appearance.preview.title')}</p>
				<div class="flex flex-wrap items-center gap-4">
					<span class="bg-primary text-primary-foreground inline-flex h-10 items-center rounded-lg px-4 text-sm font-medium">{t('appearance.preview.button')}</span>
					<span class="bg-ui-accent-soft text-ui-accent-ink inline-flex h-10 items-center rounded-lg px-3 text-sm font-semibold">{t('appearance.preview.nav')}</span>
					<span class="text-ui-accent-ink text-sm underline underline-offset-4">{t('appearance.preview.link')}</span>
				</div>
			</div>
		</Card.Content>
	</Card.Root>

	<Card.Root>
		<Card.Header><Card.Title><h2 class="panel-title">{t('appearance.language')}</h2></Card.Title></Card.Header>
		<Card.Content><LanguageSwitch compact /></Card.Content>
	</Card.Root>
</div>
