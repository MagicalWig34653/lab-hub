<script lang="ts">
	import { onMount } from 'svelte';
	import { meApi } from '#lib/api/client';
	import ErrorBanner from '#lib/components/app/ErrorBanner.svelte';
	import * as Alert from '#lib/components/ui/alert';
	import { Button } from '#lib/components/ui/button';
	import * as Card from '#lib/components/ui/card';
	import { recoveryCodesFile } from '#lib/format';
	import { errorMessage, t } from '#lib/i18n/index.svelte';

	let remaining = $state<number | null>(null);
	/** Plain-text codes exist only here, only until the user confirms; they are never stored or logged. */
	let codes = $state<string[] | null>(null);
	let confirmed = $state(false);
	let confirmReplace = $state(false);
	let pending = $state(false);
	let error = $state<string | null>(null);
	let copyState = $state<'idle' | 'copied' | 'failed'>('idle');

	async function loadStatus() {
		try {
			remaining = (await meApi.recoveryCodeStatus()).remaining;
		} catch (e) {
			error = errorMessage(e);
		}
	}
	onMount(() => void loadStatus());

	async function generate() {
		if ((remaining ?? 0) > 0 && !confirmReplace) {
			confirmReplace = true;
			return;
		}
		pending = true;
		error = null;
		try {
			codes = (await meApi.generateRecoveryCodes()).codes;
			remaining = codes.length;
			confirmed = false;
			copyState = 'idle';
		} catch (e) {
			error = errorMessage(e);
		} finally {
			pending = false;
			confirmReplace = false;
		}
	}

	async function copy() {
		try {
			await navigator.clipboard.writeText((codes ?? []).join('\n'));
			copyState = 'copied';
		} catch {
			copyState = 'failed';
		}
	}

	function download() {
		const blob = new Blob([recoveryCodesFile(t('recovery.fileTitle'), codes ?? [])], { type: 'text/plain' });
		const url = URL.createObjectURL(blob);
		const link = document.createElement('a');
		link.href = url;
		link.download = 'lab-hub-recovery-codes.txt';
		link.click();
		URL.revokeObjectURL(url);
	}

	function done() {
		codes = null;
		confirmed = false;
	}
</script>

<Card.Root data-testid="recovery-codes">
	<Card.Header>
		<Card.Title><h2 class="text-lg font-semibold">{t('recovery.title')}</h2></Card.Title>
		<Card.Description>{t('recovery.description')}</Card.Description>
	</Card.Header>
	<Card.Content class="space-y-4">
		<ErrorBanner message={error} />
		{#if codes}
			<Alert.Root data-testid="recovery-codes-once">
				<Alert.Title>{t('recovery.onceTitle')}</Alert.Title>
				<Alert.Description>{t('recovery.onceText')}</Alert.Description>
			</Alert.Root>
			<ol class="grid grid-cols-1 gap-1 font-mono text-sm sm:grid-cols-2" data-testid="recovery-code-list">
				{#each codes as code (code)}
					<li class="bg-muted rounded px-2 py-1">{code}</li>
				{/each}
			</ol>
			<div class="flex flex-wrap items-center gap-2">
				<Button variant="outline" size="sm" onclick={copy} data-testid="recovery-copy">{t('recovery.copy')}</Button>
				<Button variant="outline" size="sm" onclick={download} data-testid="recovery-download">{t('recovery.download')}</Button>
				<span role="status" class="text-muted-foreground text-sm">
					{#if copyState === 'copied'}{t('recovery.copied')}{:else if copyState === 'failed'}{t('recovery.copyFailed')}{/if}
				</span>
			</div>
			<label class="flex items-center gap-2 text-sm">
				<input type="checkbox" bind:checked={confirmed} data-testid="recovery-confirm" />
				<span>{t('recovery.confirm')}</span>
			</label>
			<Button disabled={!confirmed} onclick={done} data-testid="recovery-done">{t('recovery.done')}</Button>
		{:else}
			<p class="text-sm" data-testid="recovery-remaining">
				{remaining === null ? t('common.loading') : t('recovery.remaining', { count: remaining })}
			</p>
			{#if confirmReplace}
				<Alert.Root variant="destructive"><Alert.Description>{t('recovery.replaceWarning')}</Alert.Description></Alert.Root>
			{/if}
			<div class="flex gap-2">
				<Button disabled={pending || remaining === null} onclick={generate} data-testid="recovery-generate">
					{confirmReplace ? t('recovery.generateConfirm') : (remaining ?? 0) > 0 ? t('recovery.regenerate') : t('recovery.generate')}
				</Button>
				{#if confirmReplace}
					<Button variant="outline" onclick={() => (confirmReplace = false)}>{t('common.cancel')}</Button>
				{/if}
			</div>
		{/if}
	</Card.Content>
</Card.Root>
