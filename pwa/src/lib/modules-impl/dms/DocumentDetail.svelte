<script lang="ts">
	import { onDestroy } from 'svelte';
	import ArrowLeft from '@lucide/svelte/icons/arrow-left';
	import { dmsApi, type DmsDocument, type DmsProcessing } from '#lib/api/client';
	import ErrorBanner from '#lib/components/app/ErrorBanner.svelte';
	import * as Alert from '#lib/components/ui/alert';
	import { Button } from '#lib/components/ui/button';
	import { Input } from '#lib/components/ui/input';
	import { formatBytes, formatDate, formatDateTime } from '#lib/format';
	import { errorMessage, i18n, tx } from '#lib/i18n/index.svelte';
	import { workspace } from '#lib/workspace.svelte';
	import { loadMasters, type Masters } from './masters';
	import { isProcessingOver, isQuarantined } from './upload.svelte';

	let { tenant, id }: { tenant: string; id: string } = $props();
	// svelte-ignore state_referenced_locally
	const tenantId = tenant;
	// svelte-ignore state_referenced_locally
	const documentId = id;

	let doc = $state<DmsDocument | null>(null);
	let masters = $state<Masters>({ types: [], tags: [], fields: [], contacts: [] });
	let loadError = $state<string | null>(null);
	let loading = $state(true);

	// --- form state ---
	let title = $state('');
	let docDate = $state('');
	let typeId = $state('');
	let corrId = $state('');
	let tagIds = $state<string[]>([]);
	let fieldValues = $state<Record<string, string>>({});
	let saving = $state(false);
	let saved = $state(false);
	let formError = $state<string | null>(null);
	let titleInvalid = $state(false);

	// --- actions ---
	let trashReason = $state('');
	let reasonInvalid = $state(false);
	let actionError = $state<string | null>(null);
	let acting = $state(false);

	// --- preview ---
	let previewUrl = $state<string | null>(null);
	let previewKind = $state<'image' | 'pdf' | 'none'>('none');
	let previewError = $state<string | null>(null);

	// --- processing status (GET …/processing); polled until over, then the document is reloaded for the archive version ---
	let processing = $state<DmsProcessing | null>(null);
	let retrying = $state(false);
	let pollTimer: ReturnType<typeof setTimeout> | undefined;
	let destroyed = false;

	const canUpdate = $derived(workspace.can('dms.document.update'));
	const canTrash = $derived(workspace.can('dms.document.trash'));
	const canOriginal = $derived(workspace.can('dms.document.download_original'));
	const trashed = $derived(Boolean(doc?.trashed_at));
	const original = $derived(doc?.files?.find((f) => f.role === 'original'));

	type FieldDef = { id: string; name: string; code: string; dataType: string; options: string[] };
	const fieldDefs = $derived<FieldDef[]>(
		masters.fields.map((f) => {
			const extra = f as unknown as { code?: string; data_type?: string; options?: unknown };
			return {
				id: f.id,
				name: f.name ?? '',
				code: extra.code ?? f.id,
				dataType: extra.data_type ?? 'string',
				options: Array.isArray(extra.options) ? extra.options.map(String) : []
			};
		})
	);

	function fillForm(d: DmsDocument) {
		title = d.title;
		docDate = d.doc_date ?? '';
		typeId = d.document_type_id ?? '';
		corrId = d.correspondent_id ?? '';
		tagIds = [...(d.tag_ids ?? [])];
		const values: Record<string, string> = {};
		for (const def of fieldDefs) {
			const v = d.fields?.[def.code];
			values[def.code] = def.dataType === 'bool' ? (v === true ? 'true' : '') : v === undefined || v === null ? '' : String(v);
		}
		fieldValues = values;
	}

	async function load() {
		loading = true;
		loadError = null;
		try {
			const [d, m] = await Promise.all([dmsApi.document(tenantId, documentId), loadMasters(tenantId)]);
			masters = m;
			doc = d;
			fillForm(d);
			void loadPreview(d);
			void pollProcessing(false);
		} catch (e) {
			loadError = errorMessage(e);
		} finally {
			loading = false;
		}
	}
	void load();

	/** Preview source: the archive version, else the original (only with the download right), else a thumbnail. */
	function previewRole(d: DmsDocument): 'archive' | 'original' | 'thumbnail' | null {
		const roles = new Set((d.files ?? []).map((f) => f.role));
		if (roles.has('archive')) return 'archive';
		if (roles.has('original') && canOriginal) return 'original';
		if (roles.has('thumbnail')) return 'thumbnail';
		return null;
	}

	async function loadPreview(d: DmsDocument) {
		const role = previewRole(d);
		if (!role) return;
		try {
			const blob = await dmsApi.fileBlob(tenantId, d.id, role);
			if (blob.type === 'application/pdf') previewKind = 'pdf';
			else if (['image/png', 'image/jpeg', 'image/webp', 'image/gif'].includes(blob.type)) previewKind = 'image';
			else return;
			previewUrl = URL.createObjectURL(blob);
		} catch (e) {
			previewError = errorMessage(e);
		}
	}

	async function pollProcessing(reloadWhenDone: boolean) {
		clearTimeout(pollTimer);
		if (destroyed) return;
		try {
			processing = await dmsApi.processing(tenantId, documentId);
		} catch {
			processing = null;
			return;
		}
		if (!isProcessingOver(processing)) {
			pollTimer = setTimeout(() => void pollProcessing(true), 2000);
			return;
		}
		if (reloadWhenDone && processing.phase === 'done') {
			try {
				const d = await dmsApi.document(tenantId, documentId);
				doc = { ...(doc as DmsDocument), files: d.files, status: d.status, rev: d.rev };
				if (previewUrl) URL.revokeObjectURL(previewUrl);
				previewUrl = null;
				previewKind = 'none';
				void loadPreview(d);
			} catch {
				// the page keeps working with the data it has
			}
		}
	}

	async function retryProcessing() {
		retrying = true;
		actionError = null;
		try {
			processing = await dmsApi.retryProcessing(tenantId, documentId);
			void pollProcessing(true);
		} catch (e) {
			actionError = errorMessage(e);
		} finally {
			retrying = false;
		}
	}

	onDestroy(() => {
		destroyed = true;
		clearTimeout(pollTimer);
		if (previewUrl) URL.revokeObjectURL(previewUrl);
	});

	async function save(event: SubmitEvent) {
		event.preventDefault();
		if (!doc) return;
		saved = false;
		formError = null;
		titleInvalid = title.trim() === '';
		if (titleInvalid) {
			formError = tx('dms.edit.titleRequired');
			return;
		}
		const fields: Record<string, unknown> = {};
		for (const def of fieldDefs) {
			const v = fieldValues[def.code];
			if (def.dataType === 'bool') fields[def.code] = v === 'true';
			else if (v === '' || v === undefined) fields[def.code] = null;
			else fields[def.code] = def.dataType === 'int' ? Number(v) : String(v);
		}
		saving = true;
		try {
			const updated = await dmsApi.update(
				tenantId,
				doc.id,
				{
					title: title.trim(),
					doc_date: docDate || null,
					document_type_id: typeId || null,
					correspondent_id: corrId || null,
					tag_ids: tagIds,
					fields
				},
				doc.rev
			);
			doc = { ...doc, ...updated };
			fillForm(doc);
			saved = true;
		} catch (e) {
			formError = errorMessage(e);
		} finally {
			saving = false;
		}
	}

	async function act(run: () => Promise<DmsDocument>) {
		acting = true;
		actionError = null;
		try {
			const updated = await run();
			doc = { ...(doc as DmsDocument), ...updated };
			fillForm(doc);
		} catch (e) {
			actionError = errorMessage(e);
		} finally {
			acting = false;
		}
	}

	function trash() {
		reasonInvalid = trashReason.trim() === '';
		if (reasonInvalid) {
			actionError = tx('dms.trash.reasonRequired');
			return;
		}
		void act(() => dmsApi.trash(tenantId, documentId, trashReason.trim()));
	}

	function toggleTag(tagId: string) {
		tagIds = tagIds.includes(tagId) ? tagIds.filter((x) => x !== tagId) : [...tagIds, tagId];
	}

	const statusText = {
		processing: 'dms.status.processing',
		needs_review: 'dms.status.needsReview',
		archived: 'dms.status.archived'
	} as const;
	const phaseText = {
		none: 'dms.processing.phase.pending',
		pending: 'dms.processing.phase.pending',
		queued: 'dms.processing.phase.queued',
		processing: 'dms.processing.phase.processing',
		retrying: 'dms.processing.phase.retrying',
		done: 'dms.processing.phase.processing',
		failed: 'dms.processing.phase.processing'
	} as const;
	const selectClass = 'border-input bg-background h-8 w-full rounded-lg border px-2 text-sm disabled:opacity-50';
</script>

<p class="mb-4">
	<a href="/dms" class="inline-flex items-center gap-1 text-sm underline-offset-2 hover:underline" data-testid="dms-back">
		<ArrowLeft class="size-4" aria-hidden="true" />{tx('dms.detail.back')}
	</a>
</p>

{#if loading}
	<p class="text-muted-foreground text-sm">{tx('common.loading')}</p>
{:else if loadError || !doc}
	<ErrorBanner message={loadError} />
{:else}
	<h1 class="mb-4 text-2xl font-semibold break-words" data-testid="dms-detail-title">{doc.title}</h1>

	{#if trashed}
		<div class="mb-4" data-testid="dms-trashed-banner">
			<Alert.Root>
				<Alert.Title>{tx('dms.trash.banner')}</Alert.Title>
				<Alert.Description>{tx('dms.trash.reasonLabel')}: {doc.trash_reason ?? ''}</Alert.Description>
			</Alert.Root>
		</div>
	{/if}
	{#if isQuarantined(processing)}
		<div class="mb-4" role="alert" data-testid="dms-quarantine-banner">
			<Alert.Root variant="destructive">
				<Alert.Title>{tx('dms.status.quarantine')}</Alert.Title>
				<Alert.Description>
					{tx('dms.detail.quarantineText', { code: processing?.error_code ?? '' })}
					{#if canUpdate && !trashed}
						<Button type="button" size="sm" variant="outline" class="mt-2" disabled={retrying} onclick={retryProcessing} data-testid="dms-processing-retry">
							{tx('dms.processing.retry')}
						</Button>
					{/if}
				</Alert.Description>
			</Alert.Root>
		</div>
	{:else if processing && !isProcessingOver(processing)}
		<p role="status" class="text-muted-foreground mb-4 text-sm" data-testid="dms-processing-status">{tx(phaseText[processing.phase])}</p>
	{/if}

	<div class="grid gap-6 lg:grid-cols-2">
		<section aria-labelledby="dms-preview-title">
			<h2 id="dms-preview-title" class="mb-2 text-lg font-medium">{tx('dms.preview.title')}</h2>
			<div class="bg-muted/40 flex min-h-64 items-center justify-center rounded-md border" data-testid="dms-preview">
				{#if previewUrl && previewKind === 'image'}
					<img src={previewUrl} alt={doc.title} class="max-h-[32rem] max-w-full" data-testid="dms-preview-image" />
				{:else if previewUrl && previewKind === 'pdf'}
					<iframe src={previewUrl} title={tx('dms.preview.frame', { title: doc.title })} class="h-[32rem] w-full" data-testid="dms-preview-pdf"></iframe>
				{:else if previewError}
					<p class="text-destructive p-4 text-sm">{previewError}</p>
				{:else}
					<p class="text-muted-foreground p-4 text-sm" data-testid="dms-preview-none">{tx('dms.preview.none')}</p>
				{/if}
			</div>
			{#if canOriginal && original}
				<p class="mt-2">
					<a class="text-sm underline" href={dmsApi.fileUrl(tenantId, doc.id, 'original', 'attachment')} download data-testid="dms-download">
						{tx('dms.detail.download')}
					</a>
				</p>
			{:else}
				<p class="text-muted-foreground mt-2 text-xs" data-testid="dms-no-download">{tx('dms.detail.noDownload')}</p>
			{/if}
			<dl class="mt-4 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
				<dt class="text-muted-foreground">{tx('dms.field.status')}</dt>
				<dd data-testid="dms-detail-status">{tx(statusText[doc.status])}</dd>
				<dt class="text-muted-foreground">{tx('dms.field.asn')}</dt>
				<dd data-testid="dms-detail-asn">{doc.asn ?? '–'}</dd>
				<dt class="text-muted-foreground">{tx('dms.field.received')}</dt>
				<dd>{formatDateTime(doc.received_at, i18n.locale)}</dd>
				{#if original}
					<dt class="text-muted-foreground">{tx('dms.field.file')}</dt>
					<dd class="flex flex-wrap gap-x-3 break-all">
						<span>{original.original_name ?? ''}</span>
						<span>{original.mime}</span>
						<span>{formatBytes(original.size_bytes, i18n.locale)}</span>
						{#if original.page_count}<span>{tx('dms.field.pages', { count: original.page_count })}</span>{/if}
					</dd>
					<dt class="text-muted-foreground">{tx('dms.field.sha')}</dt>
					<dd class="font-mono text-xs break-all">{original.sha256}</dd>
				{/if}
			</dl>
		</section>

		<section aria-labelledby="dms-edit-title">
			<h2 id="dms-edit-title" class="mb-2 text-lg font-medium">{tx('dms.edit.title')}</h2>
			<form onsubmit={save} class="space-y-3" data-testid="dms-edit-form" novalidate>
				<fieldset disabled={!canUpdate || trashed || saving} class="space-y-3">
					<label class="block text-sm">
						<span class="mb-1 block">{tx('dms.field.title')}</span>
						<Input bind:value={title} aria-invalid={titleInvalid} data-testid="dms-edit-title" />
					</label>
					<label class="block text-sm">
						<span class="mb-1 block">{tx('dms.field.date')}</span>
						<Input type="date" bind:value={docDate} data-testid="dms-edit-date" />
					</label>
					<label class="block text-sm">
						<span class="mb-1 block">{tx('dms.field.type')}</span>
						<select class={selectClass} bind:value={typeId} data-testid="dms-edit-type">
							<option value="">{tx('dms.edit.none')}</option>
							{#each masters.types as type (type.id)}<option value={type.id}>{type.name}</option>{/each}
						</select>
					</label>
					<label class="block text-sm">
						<span class="mb-1 block">{tx('dms.field.correspondent')}</span>
						<select class={selectClass} bind:value={corrId} data-testid="dms-edit-corr">
							<option value="">{tx('dms.edit.none')}</option>
							{#each masters.contacts as contact (contact.id)}<option value={contact.id}>{contact.name}</option>{/each}
						</select>
					</label>
					{#if masters.tags.length > 0}
						<fieldset class="text-sm">
							<legend class="mb-1">{tx('dms.field.tags')}</legend>
							<div class="flex flex-wrap gap-x-4 gap-y-1">
								{#each masters.tags as tag (tag.id)}
									<label class="flex items-center gap-2">
										<input type="checkbox" checked={tagIds.includes(tag.id)} onchange={() => toggleTag(tag.id)} data-testid={`dms-edit-tag-${tag.name}`} />
										{tag.name}
									</label>
								{/each}
							</div>
						</fieldset>
					{/if}
					{#each fieldDefs as def (def.id)}
						{#if def.dataType === 'bool'}
							<label class="flex items-center gap-2 text-sm">
								<input type="checkbox" checked={fieldValues[def.code] === 'true'} onchange={(e) => (fieldValues[def.code] = e.currentTarget.checked ? 'true' : '')} />
								{def.name}
							</label>
						{:else if def.dataType === 'select'}
							<label class="block text-sm">
								<span class="mb-1 block">{def.name}</span>
								<select class={selectClass} bind:value={fieldValues[def.code]} data-testid={`dms-edit-field-${def.code}`}>
									<option value="">{tx('dms.edit.none')}</option>
									{#each def.options as option (option)}<option value={option}>{option}</option>{/each}
								</select>
							</label>
						{:else if ['string', 'int', 'decimal', 'date'].includes(def.dataType)}
							<label class="block text-sm">
								<span class="mb-1 block">{def.name}</span>
								<Input
									type={def.dataType === 'int' ? 'number' : def.dataType === 'date' ? 'date' : 'text'}
									inputmode={def.dataType === 'decimal' ? 'decimal' : undefined}
									bind:value={fieldValues[def.code]}
									data-testid={`dms-edit-field-${def.code}`}
								/>
							</label>
						{/if}
					{/each}
					<div class="flex flex-wrap items-center gap-3">
						<Button type="submit" disabled={!canUpdate || trashed || saving} data-testid="dms-save">{tx('dms.edit.save')}</Button>
						{#if saved}<span role="status" class="text-sm" data-testid="dms-saved">{tx('dms.edit.saved')}</span>{/if}
					</div>
				</fieldset>
				{#if formError}
					<p role="alert" class="text-destructive text-sm" data-testid="dms-edit-error">{formError}</p>
				{/if}
				{#if !canUpdate}<p class="text-muted-foreground text-xs">{tx('dms.edit.readOnly')}</p>{/if}
			</form>

			<h2 class="mt-8 mb-2 text-lg font-medium">{tx('dms.actions.title')}</h2>
			<ErrorBanner message={actionError} />
			<div class="space-y-3">
				{#if canUpdate && !trashed && doc.status !== 'archived'}
					<div>
						<Button type="button" variant="outline" disabled={acting} onclick={() => act(() => dmsApi.archive(tenantId, documentId))} data-testid="dms-archive">
							{tx('dms.actions.archive')}
						</Button>
						<p class="text-muted-foreground mt-1 text-xs">{tx('dms.actions.archiveHint')}</p>
					</div>
				{/if}
				{#if canTrash && !trashed}
					<div class="flex flex-wrap items-end gap-2">
						<label class="min-w-48 flex-1 text-sm">
							<span class="mb-1 block">{tx('dms.trash.reasonLabel')}</span>
							<Input bind:value={trashReason} aria-invalid={reasonInvalid} data-testid="dms-trash-reason" />
						</label>
						<Button type="button" variant="outline" class="text-destructive" disabled={acting} onclick={trash} data-testid="dms-trash">{tx('dms.trash.action')}</Button>
					</div>
				{/if}
				{#if canTrash && trashed}
					<Button type="button" variant="outline" disabled={acting} onclick={() => act(() => dmsApi.restore(tenantId, documentId))} data-testid="dms-restore">
						{tx('dms.trash.restore')}
					</Button>
				{/if}
			</div>
		</section>
	</div>
{/if}
