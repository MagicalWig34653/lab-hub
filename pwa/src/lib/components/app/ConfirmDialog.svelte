<script lang="ts">
	import type { Snippet } from 'svelte';
	import { Button } from '#lib/components/ui/button';
	import { tx } from '#lib/i18n/index.svelte';

	/**
	 * Modal confirmation on the native <dialog> element: the browser traps focus, Esc cancels, the page behind is inert.
	 * Focus starts on "Cancel" (the safe choice); it returns to the opener when the dialog closes.
	 */
	let {
		open,
		title,
		confirmLabel,
		busy = false,
		error = null,
		destructive = false,
		testid = 'confirm',
		onconfirm,
		oncancel,
		children
	}: {
		open: boolean;
		title: string;
		confirmLabel: string;
		busy?: boolean;
		error?: string | null;
		destructive?: boolean;
		testid?: string;
		onconfirm: () => void;
		oncancel: () => void;
		children?: Snippet;
	} = $props();

	let dialog = $state<HTMLDialogElement | null>(null);
	let cancelButton = $state<HTMLButtonElement | null>(null);

	$effect(() => {
		if (!dialog) return;
		if (open && !dialog.open) {
			dialog.showModal();
			cancelButton?.focus();
		} else if (!open && dialog.open) dialog.close();
	});
</script>

<dialog
	bind:this={dialog}
	aria-labelledby={`${testid}-title`}
	class="bg-background text-foreground m-auto w-[min(32rem,calc(100vw-2rem))] rounded-lg border p-5 shadow-lg backdrop:bg-black/50"
	data-testid={testid}
	oncancel={(event) => {
		event.preventDefault();
		oncancel();
	}}
>
	<h2 id={`${testid}-title`} class="mb-2 text-lg font-semibold">{title}</h2>
	<div class="space-y-3 text-sm">
		{@render children?.()}
		{#if error}
			<p role="alert" class="text-destructive" data-testid={`${testid}-error`}>{error}</p>
		{/if}
	</div>
	<div class="mt-5 flex justify-end gap-2">
		<button
			bind:this={cancelButton}
			type="button"
			class="border-border bg-background hover:bg-muted focus-visible:ring-ring/50 h-8 rounded-lg border px-2.5 text-sm font-medium focus-visible:ring-3"
			onclick={oncancel}
			data-testid={`${testid}-cancel`}
		>
			{tx('common.cancel')}
		</button>
		<Button type="button" variant={destructive ? 'outline' : 'default'} class={destructive ? 'text-destructive' : ''} disabled={busy} onclick={onconfirm} data-testid={`${testid}-confirm`}>
			{confirmLabel}
		</Button>
	</div>
</dialog>
