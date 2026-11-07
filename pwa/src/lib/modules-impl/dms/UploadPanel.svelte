<script lang="ts">
	import { onDestroy } from 'svelte';
	import UploadIcon from '@lucide/svelte/icons/upload';
	import { dmsApi, type DmsDocument } from '#lib/api/client';
	import { Button } from '#lib/components/ui/button';
	import { formatBytes } from '#lib/format';
	import { errorMessage, i18n, tx } from '#lib/i18n/index.svelte';
	import { workspace } from '#lib/workspace.svelte';
	import { UploadQueue } from './upload.svelte';

	let { tenant, onSettled }: { tenant: string; onSettled?: (doc: DmsDocument) => void } = $props();

	// One panel instance per tenant: the page is re-keyed on tenant switch, so `tenant` is stable for its lifetime.
	// svelte-ignore state_referenced_locally
	const tenantId = tenant;
	const queue = new UploadQueue({
		upload: (file, o) =>
			dmsApi.upload(tenantId, file, { filename: file.name, idempotencyKey: o.idempotencyKey, onProgress: o.onProgress, signal: o.signal }),
		fetchProcessing: (id) => dmsApi.processing(tenantId, id),
		retryProcessing: (id) => dmsApi.retryProcessing(tenantId, id),
		onSettled: (doc) => onSettled?.(doc)
	});
	onDestroy(() => queue.destroy());

	let input = $state<HTMLInputElement | null>(null);
	let dragging = $state(false);

	function pick(event: Event) {
		const el = event.currentTarget as HTMLInputElement;
		if (el.files) queue.add(Array.from(el.files));
		el.value = '';
	}

	function drop(event: DragEvent) {
		event.preventDefault();
		dragging = false;
		if (event.dataTransfer?.files) queue.add(Array.from(event.dataTransfer.files));
	}

	const stateText: Record<string, string> = {
		waiting: 'dms.upload.state.waiting',
		processing: 'dms.upload.state.processing',
		done: 'dms.upload.state.done',
		duplicate: 'dms.upload.state.duplicate',
		quarantine: 'dms.upload.state.quarantine'
	};
	const failureText = {
		unsupported: 'dms.upload.error.unsupported',
		too_large: 'dms.upload.error.tooLarge',
		quota: 'dms.upload.error.quota'
	} as const;
</script>

<section aria-labelledby="dms-upload-title" class="mb-6" data-testid="dms-upload">
	<h2 id="dms-upload-title" class="mb-2 text-lg font-medium">{tx('dms.upload.title')}</h2>
	<!-- The drop target is a convenience; the file button is the accessible path. -->
	<div
		role="presentation"
		class="flex flex-col items-center gap-2 rounded-lg border-2 border-dashed p-6 text-center transition-colors {dragging ? 'border-ring bg-muted' : ''}"
		data-testid="dms-dropzone"
		ondragover={(e) => {
			e.preventDefault();
			dragging = true;
		}}
		ondragleave={() => (dragging = false)}
		ondrop={drop}
	>
		<p class="text-muted-foreground text-sm">{tx('dms.upload.hint')}</p>
		<Button type="button" variant="outline" onclick={() => input?.click()} data-testid="dms-upload-button">
			<UploadIcon class="size-4" aria-hidden="true" />{tx('dms.upload.choose')}
		</Button>
		<input
			bind:this={input}
			type="file"
			multiple
			hidden
			accept="application/pdf,image/png,image/jpeg,image/tiff,image/webp"
			onchange={pick}
			data-testid="dms-file-input"
		/>
	</div>

	{#if queue.items.length > 0}
		<ul class="mt-3 space-y-2" data-testid="dms-upload-list">
			{#each queue.items as item (item.id)}
				<li class="rounded-md border p-3 text-sm" data-testid="dms-upload-item" data-state={item.state}>
					<div class="flex flex-wrap items-center justify-between gap-2">
						<span class="font-medium break-all">{item.name}</span>
						<span class="text-muted-foreground">{formatBytes(item.size, i18n.locale)}</span>
					</div>
					{#if item.state === 'uploading'}
						<progress class="mt-2 h-2 w-full" value={item.progress} max="1" aria-label={item.name}></progress>
						<p role="status" class="text-muted-foreground mt-1">{tx('dms.upload.state.uploading', { percent: Math.round(item.progress * 100) })}</p>
					{:else if item.state === 'error'}
						<p role="alert" class="text-destructive mt-1" data-testid="dms-upload-error" data-failure={item.failure}>
							{#if item.failure === 'unsupported' || item.failure === 'too_large' || item.failure === 'quota'}
								{tx(failureText[item.failure])}
							{:else}
								{errorMessage(item.error)}
							{/if}
						</p>
					{:else if item.state === 'quarantine'}
						<p role="alert" class="text-destructive mt-1" data-testid="dms-upload-quarantine">
							{tx(stateText.quarantine, { code: item.processing?.error_code ?? '' })}
						</p>
					{:else if item.state === 'duplicate'}
						<p role="status" class="mt-1" data-testid="dms-upload-duplicate">
							{tx(stateText.duplicate)}
							{#each item.duplicates as id (id)}
								<a class="underline" href={`/dms/${id}`}>{tx('dms.upload.openExisting')}</a>
							{/each}
						</p>
					{:else}
						<p role="status" class="text-muted-foreground mt-1" data-testid={`dms-upload-${item.state}`}>
							{tx(stateText[item.state])}
							{#if item.state === 'done' && item.document}
								<a class="text-foreground ml-1 underline" href={`/dms/${item.document.id}`}>{tx('dms.upload.open')}</a>
							{/if}
						</p>
					{/if}
					<div class="mt-2 flex gap-2">
						{#if item.state === 'error' && item.failure === 'other'}
							<Button type="button" size="sm" variant="outline" onclick={() => queue.retry(item.id)}>{tx('dms.upload.retry')}</Button>
						{/if}
						{#if item.state === 'quarantine' && workspace.can('dms.document.update')}
							<Button type="button" size="sm" variant="outline" onclick={() => queue.retryQuarantine(item.id)} data-testid="dms-upload-retry-processing">
								{tx('dms.processing.retry')}
							</Button>
						{/if}
						{#if item.state !== 'uploading'}
							<Button type="button" size="sm" variant="ghost" onclick={() => queue.remove(item.id)}>{tx('dms.upload.dismiss')}</Button>
						{/if}
					</div>
				</li>
			{/each}
		</ul>
	{/if}
</section>
