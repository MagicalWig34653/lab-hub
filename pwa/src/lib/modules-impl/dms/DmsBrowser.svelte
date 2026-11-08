<script lang="ts">
	import { untrack } from 'svelte';
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { dmsApi, type DmsDocument, type DmsFacets, type DmsProcessing, type DmsSearchHit } from '#lib/api/client';
	import ErrorBanner from '#lib/components/app/ErrorBanner.svelte';
	import { Button } from '#lib/components/ui/button';
	import { Input } from '#lib/components/ui/input';
	import { formatDate } from '#lib/format';
	import { errorMessage, i18n, tx } from '#lib/i18n/index.svelte';
	import { workspace } from '#lib/workspace.svelte';
	import { loadMasters, nameOf, type Masters } from './masters';
	import { parseSnippet } from './snippet';
	import { isProcessingOver, isQuarantined } from './upload.svelte';
	import UploadPanel from './UploadPanel.svelte';

	let { tenant }: { tenant: string } = $props();
	// The page is re-keyed on tenant switch, so the tenant is fixed for the lifetime of this component.
	// svelte-ignore state_referenced_locally
	const tenantId = tenant;

	interface Row {
		id: string;
		title: string;
		doc_date?: string | null;
		document_type_id?: string | null;
		correspondent_id?: string | null;
		asn?: number | null;
		status: DmsDocument['status'];
		snippet?: string | null;
		created_at: string;
	}

	const fromDoc = (d: DmsDocument): Row => ({ ...d });
	const fromHit = (h: DmsSearchHit): Row => ({ ...h });

	// --- filter state lives in the URL (reload, back button, shareable) ---
	const sp = $derived(page.url.searchParams);
	const q = $derived(sp.get('q') ?? '');
	const typeId = $derived(sp.get('type') ?? '');
	const corrId = $derived(sp.get('corr') ?? '');
	const tagIds = $derived((sp.get('tags') ?? '').split(',').filter(Boolean));
	const dateFrom = $derived(sp.get('from') ?? '');
	const dateTo = $derived(sp.get('to') ?? '');
	const trashed = $derived(sp.get('trash') === '1');
	const searching = $derived(q !== '' && !trashed);
	/** Everything except the trash view runs on `GET …/search` (an empty term browses, snippet null). */
	const browsing = $derived(!trashed);
	const filterKey = $derived([q, typeId, corrId, tagIds.join(','), dateFrom, dateTo, trashed].join('|'));

	function setParams(update: Record<string, string | null>) {
		const next = new URLSearchParams(page.url.searchParams.toString());
		for (const [key, value] of Object.entries(update)) {
			if (value === null || value === '') next.delete(key);
			else next.set(key, value);
		}
		const text = next.toString();
		void goto(text ? `?${text}` : page.url.pathname, { replace: true, reset: false });
	}

	let masters = $state<Masters>({ types: [], tags: [], fields: [], paths: [], contacts: [] });
	let rows = $state<Row[]>([]);
	let nextCursor = $state<string | null>(null);
	let facets = $state<DmsFacets | null>(null);
	let loading = $state(true);
	let error = $state<string | null>(null);
	let seq = 0;
	let qInput = $state('');
	let searchInput = $state<HTMLInputElement | null>(null);
	let listEl = $state<HTMLUListElement | null>(null);
	let active = $state(0);

	$effect(() => {
		qInput = q;
	});

	void loadMasters(tenantId).then((m) => (masters = m));

	async function load(reset: boolean) {
		const mine = ++seq;
		loading = true;
		error = null;
		const cursor = reset ? null : nextCursor;
		try {
			let items: Row[];
			let next: string | null | undefined;
			if (browsing) {
				const result = await dmsApi.search(tenantId, {
					q,
					cursor,
					limit: 25,
					facets: true,
					document_type_id: typeId || undefined,
					correspondent_id: corrId || undefined,
					tag_id: tagIds.join(',') || undefined,
					date_from: dateFrom || undefined,
					date_to: dateTo || undefined
				});
				items = result.items.map(fromHit);
				next = result.next_cursor;
				if (mine === seq) facets = result.facets ?? null;
			} else {
				// The trash is only reachable through the list route (search excludes trashed documents).
				const result = await dmsApi.documents(tenantId, {
					trashed,
					q: q || undefined,
					cursor,
					limit: 25,
					document_type_id: typeId || undefined,
					correspondent_id: corrId || undefined,
					tag_id: tagIds[0] || undefined
				});
				items = result.items.map(fromDoc);
				next = result.next_cursor;
				if (mine === seq) facets = null;
			}
			if (mine !== seq) return;
			rows = reset ? items : [...rows, ...items];
			nextCursor = next ?? null;
			void loadProcessing(items);
			if (reset) active = 0;
		} catch (e) {
			if (mine === seq) error = errorMessage(e);
		} finally {
			if (mine === seq) loading = false;
		}
	}

	// --- processing / quarantine marker: the list rows carry no ingest state, so recent unarchived rows are asked ---
	let processing = $state<Record<string, DmsProcessing>>({});
	const RECENT_MS = 3 * 24 * 3600 * 1000;

	async function loadProcessing(items: Row[]) {
		const wanted = items.filter((r) => r.status !== 'archived' && Date.now() - Date.parse(r.created_at) < RECENT_MS);
		let index = 0;
		const worker = async () => {
			while (index < wanted.length) {
				const row = wanted[index++];
				try {
					processing[row.id] = await dmsApi.processing(tenantId, row.id);
				} catch {
					// the marker is a convenience; the list works without it
				}
			}
		};
		await Promise.all([worker(), worker(), worker()]);
	}

	$effect(() => {
		void filterKey;
		untrack(() => void load(true));
	});

	/** Documents uploaded in this session appear (and processing results update) without a manual reload. */
	function refreshAfterUpload() {
		if (!trashed) void load(true);
	}

	// --- keyboard: arrows/j/k/Home/End move between rows, Enter opens, "/" focuses the search ---
	function links(): HTMLAnchorElement[] {
		return listEl ? Array.from(listEl.querySelectorAll<HTMLAnchorElement>('a[data-row-link]')) : [];
	}

	function focusRow(index: number) {
		const all = links();
		if (all.length === 0) return;
		const clamped = Math.max(0, Math.min(all.length - 1, index));
		active = clamped;
		all[clamped].focus();
	}

	function onListKey(event: KeyboardEvent) {
		const all = links();
		const current = all.indexOf(document.activeElement as HTMLAnchorElement);
		if (current < 0 || event.altKey || event.ctrlKey || event.metaKey) return;
		const move: Record<string, number> = { ArrowDown: current + 1, j: current + 1, ArrowUp: current - 1, k: current - 1, Home: 0, End: all.length - 1 };
		if (event.key in move) {
			event.preventDefault();
			focusRow(move[event.key]);
		}
	}

	function onWindowKey(event: KeyboardEvent) {
		const target = event.target as HTMLElement | null;
		if (event.key !== '/' || event.ctrlKey || event.metaKey || event.altKey) return;
		if (target && ['INPUT', 'TEXTAREA', 'SELECT'].includes(target.tagName)) return;
		event.preventDefault();
		searchInput?.focus();
	}

	function toggleTag(id: string) {
		setParams({ tags: (tagIds.includes(id) ? tagIds.filter((x) => x !== id) : [...tagIds, id]).join(',') });
	}

	const facetName = (kind: 'document_type' | 'tag' | 'correspondent' | 'year', value: string) =>
		kind === 'document_type' ? nameOf(masters.types, value) || value : kind === 'tag' ? nameOf(masters.tags, value) || value : kind === 'correspondent' ? nameOf(masters.contacts, value) || value : value;

	const facetPressed = (kind: string, value: string) =>
		kind === 'document_type'
			? typeId === value
			: kind === 'correspondent'
				? corrId === value
				: kind === 'tag'
					? tagIds.includes(value)
					: dateFrom === `${value}-01-01` && dateTo === `${value}-12-31`;

	function facetToggle(kind: string, value: string) {
		if (kind === 'document_type') setParams({ type: typeId === value ? null : value });
		else if (kind === 'correspondent') setParams({ corr: corrId === value ? null : value });
		else if (kind === 'tag') toggleTag(value);
		else if (facetPressed(kind, value)) setParams({ from: null, to: null });
		else setParams({ from: `${value}-01-01`, to: `${value}-12-31` });
	}

	const facetGroups = $derived(
		facets
			? ([
					['document_type', 'dms.facet.type', facets.document_type],
					['correspondent', 'dms.facet.correspondent', facets.correspondent],
					['tag', 'dms.facet.tag', facets.tag],
					['year', 'dms.facet.year', facets.year]
				] as const).filter(([, , entries]) => entries && entries.length > 0)
			: []
	);

	const statusText = {
		processing: 'dms.status.processing',
		needs_review: 'dms.status.needsReview',
		archived: 'dms.status.archived'
	} as const;

	const hasFilters = $derived(Boolean(q || typeId || corrId || tagIds.length || dateFrom || dateTo || trashed));
	const selectClass = 'border-input bg-background h-8 w-full rounded-lg border px-2 text-sm';
</script>

<svelte:window onkeydown={onWindowKey} />

<h1 class="mb-4 text-2xl font-semibold">{tx('dms.title')}</h1>

{#if workspace.can('dms.document.create')}
	<UploadPanel tenant={tenantId} onSettled={refreshAfterUpload} />
{/if}

<section aria-labelledby="dms-list-title">
	<h2 id="dms-list-title" class="sr-only">{tx('dms.list.title')}</h2>

	<form
		role="search"
		class="mb-3 flex flex-wrap gap-2"
		onsubmit={(e) => {
			e.preventDefault();
			setParams({ q: qInput.trim() });
		}}
	>
		<label class="min-w-48 flex-1">
			<span class="sr-only">{tx('dms.search.label')}</span>
			<Input type="search" bind:ref={searchInput} bind:value={qInput} placeholder={tx('dms.search.placeholder')} data-testid="dms-search" />
		</label>
		<Button type="submit" data-testid="dms-search-submit">{tx('dms.search.submit')}</Button>
	</form>
	<p class="text-muted-foreground mb-3 text-xs">{tx('dms.search.shortcuts')}</p>

	<details class="mb-4 rounded-md border p-3" open={hasFilters} data-testid="dms-filters">
		<summary class="cursor-pointer text-sm font-medium">{tx('dms.filter.title')}</summary>
		<div class="mt-3 grid gap-3 sm:grid-cols-2">
			<label class="text-sm">
				<span class="mb-1 block">{tx('dms.field.type')}</span>
				<select class={selectClass} value={typeId} onchange={(e) => setParams({ type: e.currentTarget.value })} data-testid="dms-filter-type">
					<option value="">{tx('dms.filter.all')}</option>
					{#each masters.types as type (type.id)}<option value={type.id}>{type.name}</option>{/each}
				</select>
			</label>
			<label class="text-sm">
				<span class="mb-1 block">{tx('dms.field.correspondent')}</span>
				<select class={selectClass} value={corrId} onchange={(e) => setParams({ corr: e.currentTarget.value })} data-testid="dms-filter-corr">
					<option value="">{tx('dms.filter.all')}</option>
					{#each masters.contacts as contact (contact.id)}<option value={contact.id}>{contact.name}</option>{/each}
				</select>
			</label>
			<label class="text-sm">
				<span class="mb-1 block">{tx('dms.filter.dateFrom')}</span>
				<Input type="date" value={dateFrom} disabled={!browsing} onchange={(e) => setParams({ from: e.currentTarget.value })} data-testid="dms-filter-from" />
			</label>
			<label class="text-sm">
				<span class="mb-1 block">{tx('dms.filter.dateTo')}</span>
				<Input type="date" value={dateTo} disabled={!browsing} onchange={(e) => setParams({ to: e.currentTarget.value })} data-testid="dms-filter-to" />
			</label>
		</div>
		{#if !browsing}<p class="text-muted-foreground mt-1 text-xs">{tx('dms.filter.trashLimited')}</p>{/if}
		{#if masters.tags.length > 0}
			<fieldset class="mt-3">
				<legend class="mb-1 text-sm">{tx('dms.field.tags')}</legend>
				<div class="flex flex-wrap gap-x-4 gap-y-1">
					{#each masters.tags as tag (tag.id)}
						<label class="flex items-center gap-2 text-sm">
							<input type="checkbox" checked={tagIds.includes(tag.id)} onchange={() => toggleTag(tag.id)} data-testid={`dms-filter-tag-${tag.name}`} />
							{tag.name}
						</label>
					{/each}
				</div>
			</fieldset>
		{/if}
		<div class="mt-3 flex flex-wrap items-center justify-between gap-2">
			<label class="flex items-center gap-2 text-sm">
				<input type="checkbox" checked={trashed} onchange={(e) => setParams({ trash: e.currentTarget.checked ? '1' : null })} data-testid="dms-trash-toggle" />
				{tx('dms.filter.trash')}
			</label>
			{#if hasFilters}
				<Button type="button" variant="ghost" size="sm" onclick={() => setParams({ q: null, type: null, corr: null, tags: null, from: null, to: null, trash: null })}>
					{tx('dms.filter.reset')}
				</Button>
			{/if}
		</div>
	</details>

	{#if facetGroups.length > 0}
		<div class="mb-4 space-y-2" data-testid="dms-facets">
			{#each facetGroups as [kind, labelKey, entries] (kind)}
				<div class="flex flex-wrap items-center gap-2" role="group" aria-label={tx(labelKey)}>
					<span class="text-muted-foreground text-xs">{tx(labelKey)}</span>
					{#each entries ?? [] as entry (entry.value)}
						<button
							type="button"
							class="hover:bg-muted aria-pressed:bg-primary aria-pressed:text-primary-foreground rounded-full border px-2.5 py-0.5 text-xs"
							aria-pressed={facetPressed(kind, entry.value)}
							onclick={() => facetToggle(kind, entry.value)}
							data-testid={`dms-facet-${kind}`}
						>
							{facetName(kind, entry.value)} ({entry.count})
						</button>
					{/each}
				</div>
			{/each}
		</div>
	{/if}

	<ErrorBanner message={error} />

	<p role="status" aria-live="polite" class="text-muted-foreground mb-2 text-sm" data-testid="dms-count">
		{#if loading && rows.length === 0}
			{tx('common.loading')}
		{:else if trashed}
			{tx('dms.list.countTrash', { count: rows.length })}
		{:else}
			{tx(searching ? 'dms.list.countHits' : 'dms.list.count', { count: rows.length })}
		{/if}
	</p>

	{#if !loading && rows.length === 0 && !error}
		<p class="text-muted-foreground rounded-md border p-6 text-center" data-testid="dms-empty">
			{#if searching}{tx('dms.list.noHits', { query: q })}{:else if trashed}{tx('dms.list.trashEmpty')}{:else}{tx('dms.list.empty')}{/if}
		</p>
	{/if}

	{#if rows.length > 0}
		<!-- Roving tabindex: one tab stop for the list, arrow keys inside (AK-F4-3). -->
		<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
		<ul bind:this={listEl} class="divide-y rounded-md border" aria-label={tx('dms.list.title')} onkeydown={onListKey} data-testid="dms-list">
			{#each rows as row, index (row.id)}
				<li class="p-3" data-testid="dms-row">
					<a
						href={`/dms/${row.id}`}
						class="focus-visible:ring-ring/50 block rounded-md font-medium underline-offset-2 hover:underline focus-visible:ring-3 focus-visible:outline-none"
						tabindex={index === active ? 0 : -1}
						data-row-link
						onfocus={() => (active = index)}
					>
						{row.title}
					</a>
					<p class="text-muted-foreground mt-0.5 flex flex-wrap gap-x-3 text-xs">
						{#if row.doc_date}<span>{formatDate(row.doc_date, i18n.locale)}</span>{/if}
						{#if row.document_type_id}<span>{nameOf(masters.types, row.document_type_id)}</span>{/if}
						{#if row.correspondent_id}<span>{nameOf(masters.contacts, row.correspondent_id)}</span>{/if}
						{#if row.asn}<span>{tx('dms.field.asn')} {row.asn}</span>{/if}
						{#if isQuarantined(processing[row.id])}
							<span class="text-destructive font-medium" data-testid="dms-row-quarantine">{tx('dms.status.quarantine')}</span>
						{:else if processing[row.id] && !isProcessingOver(processing[row.id])}
							<span data-testid="dms-row-status">{tx('dms.status.processing')}</span>
						{:else}
							<span data-testid="dms-row-status">{tx(statusText[row.status])}</span>
						{/if}
					</p>
					{#if row.snippet}
						<!-- Snippet markers become <mark>; the text itself is inserted as text, never as HTML. -->
						<p class="mt-1 text-sm" data-testid="dms-snippet">
							{#each parseSnippet(row.snippet) as part, i (i)}{#if part.mark}<mark class="rounded-sm bg-amber-200 px-0.5 text-black dark:bg-amber-400">{part.text}</mark>{:else}{part.text}{/if}{/each}
						</p>
					{/if}
				</li>
			{/each}
		</ul>
	{/if}

	{#if nextCursor}
		<div class="mt-3 text-center">
			<Button type="button" variant="outline" disabled={loading} onclick={() => load(false)} data-testid="dms-more">{tx('dms.list.more')}</Button>
		</div>
	{/if}
</section>
