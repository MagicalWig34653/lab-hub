<script lang="ts">
	import { untrack } from 'svelte';
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import ArrowDown from '@lucide/svelte/icons/arrow-down';
	import ArrowUp from '@lucide/svelte/icons/arrow-up';
	import { dmsAdminApi, dmsApi, type DmsDocument, type DmsExtraction, type DmsFacets, type DmsProcessing, type DmsSearchHit } from '#lib/api/client';
	import ErrorBanner from '#lib/components/app/ErrorBanner.svelte';
	import { Button } from '#lib/components/ui/button';
	import { Input } from '#lib/components/ui/input';
	import { formatDate } from '#lib/format';
	import { errorMessage, i18n, tx } from '#lib/i18n/index.svelte';
	import { workspace } from '#lib/workspace.svelte';
	import KindBadge from './KindBadge.svelte';
	import { loadMasters, nameOf, type Masters } from './masters';
	import {
		KIND_LABEL,
		KINDS,
		activePreset,
		defaultOrder,
		formatMoney,
		hasAnyFilter,
		isOverdue,
		localToday,
		normalizeAmount,
		parseFilters,
		presetRange,
		toListQuery,
		toSearchQuery,
		usesListRoute,
		type DatePreset,
		type SortKey
	} from './overview';
	import { P } from './permissions';
	import { parseSnippet } from './snippet';
	import { isProcessingOver, isQuarantined } from './upload.svelte';
	import UploadPanel from './UploadPanel.svelte';

	/**
	 * Central document table (WP-F4c): one calm overview for all document kinds. Filters, sorting and the search term live in the URL.
	 * Default and full-text search run on `GET …/search` (snippets, facets, several tags, document date); extraction filters, sorting by
	 * date/amount/due date and the trash run on `GET …/documents` (the contract offers these filters only there).
	 */
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
		/** From the list route; search hits carry none (loaded afterwards). */
		extraction?: DmsExtraction | null;
	}

	const fromDoc = (d: DmsDocument): Row => ({ ...d, extraction: d.extraction ?? null });
	const fromHit = (h: DmsSearchHit): Row => ({ ...h });

	// --- filter state lives in the URL (reload, back button, shareable) ---
	const f = $derived(parseFilters(new URLSearchParams(page.url.searchParams.toString())));
	const listRoute = $derived(usesListRoute(f));
	const searching = $derived(f.q !== '' && !listRoute);
	const filterKey = $derived(JSON.stringify(f));
	const today = $derived(localToday());
	const preset = $derived(activePreset(f, today));

	// Two quick changes must both survive: the second starts from the URL the first one is navigating to.
	let pending: URLSearchParams | null = null;
	$effect(() => {
		void page.url.search;
		pending = null;
	});

	function setParams(update: Record<string, string | null>) {
		const next = new URLSearchParams((pending ?? page.url.searchParams).toString());
		for (const [key, value] of Object.entries(update)) {
			if (value === null || value === '') next.delete(key);
			else next.set(key, value);
		}
		pending = next;
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
	let tableEl = $state<HTMLTableElement | null>(null);
	let active = $state(0);
	let minInvalid = $state(false);
	let maxInvalid = $state(false);

	// A primitive: the input is only overwritten when the term in the URL really changes (not on every filter change).
	const urlTerm = $derived(f.q);
	$effect(() => {
		qInput = urlTerm;
	});

	void loadMasters(tenantId).then((m) => (masters = m));

	// --- open suggestions per document (for the status column and the "only open suggestions" filter) ---
	let suggestionCount = $state<Record<string, number>>({});
	let suggestionsCapped = $state(false);
	const canSuggestions = $derived(workspace.can(P.suggestionRead));

	async function loadSuggestionCounts() {
		if (!canSuggestions) return;
		const counts: Record<string, number> = {};
		let cursor: string | null = null;
		try {
			for (let i = 0; i < 5; i++) {
				const result = await dmsAdminApi.suggestions(tenantId, { state: 'open', limit: 200, cursor });
				for (const s of result.items) counts[s.document_id] = (counts[s.document_id] ?? 0) + 1;
				cursor = result.next_cursor;
				if (!cursor) break;
			}
			suggestionsCapped = cursor !== null;
			suggestionCount = counts;
		} catch {
			// the marker is a convenience; the table works without it
		}
	}
	void loadSuggestionCounts();

	const visibleRows = $derived(f.open ? rows.filter((r) => (suggestionCount[r.id] ?? 0) > 0) : rows);

	async function load(reset: boolean, fills = 0) {
		const mine = ++seq;
		loading = true;
		error = null;
		const cursor = reset ? null : nextCursor;
		try {
			let items: Row[];
			let next: string | null | undefined;
			if (listRoute) {
				const result = await dmsApi.documents(tenantId, toListQuery(f, today, cursor));
				items = result.items.map(fromDoc);
				next = result.next_cursor;
				if (mine === seq) facets = null;
			} else {
				const result = await dmsApi.search(tenantId, toSearchQuery(f, cursor));
				items = result.items.map(fromHit);
				next = result.next_cursor;
				if (mine === seq) facets = result.facets ?? null;
			}
			if (mine !== seq) return;
			rows = reset ? items : [...rows, ...items];
			nextCursor = next ?? null;
			void loadProcessing(items);
			if (!listRoute) void loadExtractions(items);
			if (reset) active = 0;
			// "Only open suggestions" narrows the loaded pages on the client: keep paging until a page's worth is visible.
			if (f.open && nextCursor && fills < 8 && rows.filter((r) => (suggestionCount[r.id] ?? 0) > 0).length < 25) {
				await load(false, fills + 1);
			}
		} catch (e) {
			if (mine === seq) error = errorMessage(e);
		} finally {
			if (mine === seq) loading = false;
		}
	}

	// --- processing / quarantine marker: the table rows carry no ingest state, so recent unarchived rows are asked ---
	let processing = $state<Record<string, DmsProcessing>>({});
	const RECENT_MS = 3 * 24 * 3600 * 1000;

	async function parallel<T>(items: T[], run: (item: T) => Promise<void>, workers: number) {
		let index = 0;
		const worker = async () => {
			while (index < items.length) {
				const item = items[index++];
				try {
					await run(item);
				} catch {
					// convenience data; the table works without it
				}
			}
		};
		await Promise.all(Array.from({ length: workers }, worker));
	}

	async function loadProcessing(items: Row[]) {
		const wanted = items.filter((r) => r.status !== 'archived' && Date.now() - Date.parse(r.created_at) < RECENT_MS);
		await parallel(wanted, async (row) => void (processing[row.id] = await dmsApi.processing(tenantId, row.id)), 3);
	}

	// Search hits carry no extraction: kind, amount and due date are fetched per row (the contract's hit has no such fields).
	let fetched = $state<Record<string, DmsExtraction | null>>({});
	async function loadExtractions(items: Row[]) {
		const wanted = items.filter((r) => !(r.id in fetched));
		await parallel(wanted, async (row) => void (fetched[row.id] = (await dmsApi.document(tenantId, row.id)).extraction ?? null), 4);
	}
	const extractionOf = (row: Row): DmsExtraction | null => (listRoute ? (row.extraction ?? null) : (fetched[row.id] ?? null));

	$effect(() => {
		void filterKey;
		untrack(() => void load(true));
	});

	/** Documents uploaded in this session appear (and processing results update) without a manual reload. */
	function refreshAfterUpload() {
		if (!f.trash) void load(true);
		void loadSuggestionCounts();
	}

	// --- keyboard: arrows/j/k/Home/End move between rows, Enter opens, "/" focuses the search ---
	function links(): HTMLAnchorElement[] {
		return tableEl ? Array.from(tableEl.querySelectorAll<HTMLAnchorElement>('a[data-row-link]')) : [];
	}

	function focusRow(index: number) {
		const all = links();
		if (all.length === 0) return;
		const clamped = Math.max(0, Math.min(all.length - 1, index));
		active = clamped;
		all[clamped].focus();
	}

	function onTableKey(event: KeyboardEvent) {
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

	// --- filter actions ---
	function toggleTag(id: string) {
		setParams({ tags: (f.tags.includes(id) ? f.tags.filter((x) => x !== id) : [...f.tags, id]).join(',') });
	}

	function applyPreset(p: DatePreset | null) {
		if (p === null || p === preset) return setParams({ from: null, to: null });
		const range = presetRange(p, today);
		setParams({ from: range.from, to: range.to });
	}

	function commitAmount(which: 'min' | 'max', text: string) {
		const value = text.trim() === '' ? '' : normalizeAmount(text);
		if (value === null) {
			if (which === 'min') minInvalid = true;
			else maxInvalid = true;
			return;
		}
		if (which === 'min') minInvalid = false;
		else maxInvalid = false;
		setParams({ [which]: value });
	}

	/** Sort and direction are one select; the default (newest received first) leaves the URL clean. */
	const sortValue = $derived(`${f.sort}:${f.order}`);
	function applySort(sort: SortKey, order: 'asc' | 'desc') {
		const isDefault = sort === 'received' && order === 'desc';
		setParams({ sort: isDefault ? null : sort, order: isDefault ? null : order });
	}
	function onSortSelect(value: string) {
		const [sort, order] = value.split(':') as [SortKey, 'asc' | 'desc'];
		applySort(sort, order);
	}
	/** Column header: first click = default direction, second = reversed, third = back to the default order. */
	function cycleSort(key: Exclude<SortKey, 'received'>) {
		if (f.sort !== key) return applySort(key, defaultOrder(key));
		if (f.order === defaultOrder(key)) return applySort(key, f.order === 'asc' ? 'desc' : 'asc');
		applySort('received', 'desc');
	}
	const ariaSort = (key: SortKey) => (f.sort === key ? (f.order === 'asc' ? 'ascending' : 'descending') : 'none');

	const SORT_OPTIONS = [
		['received:desc', 'dms.sort.received.desc'],
		['received:asc', 'dms.sort.received.asc'],
		['date:desc', 'dms.sort.date.desc'],
		['date:asc', 'dms.sort.date.asc'],
		['amount:desc', 'dms.sort.amount.desc'],
		['amount:asc', 'dms.sort.amount.asc'],
		['due:asc', 'dms.sort.due.asc'],
		['due:desc', 'dms.sort.due.desc']
	] as const;

	const facetName = (kind: 'document_type' | 'tag' | 'correspondent' | 'year', value: string) =>
		kind === 'document_type' ? nameOf(masters.types, value) || value : kind === 'tag' ? nameOf(masters.tags, value) || value : kind === 'correspondent' ? nameOf(masters.contacts, value) || value : value;

	const facetPressed = (kind: string, value: string) =>
		kind === 'document_type'
			? f.type === value
			: kind === 'correspondent'
				? f.corr === value
				: kind === 'tag'
					? f.tags.includes(value)
					: f.from === `${value}-01-01` && f.to === `${value}-12-31`;

	function facetToggle(kind: string, value: string) {
		if (kind === 'document_type') setParams({ type: f.type === value ? null : value });
		else if (kind === 'correspondent') setParams({ corr: f.corr === value ? null : value });
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

	const detailsOpen = $derived(Boolean(f.type || f.corr || f.tags.length || f.from || f.to || f.trash || f.open || f.cur));
	const selectClass = 'border-input bg-background h-8 w-full rounded-lg border px-2 text-sm';
	const presetClass = 'hover:bg-muted aria-pressed:bg-primary aria-pressed:text-primary-foreground focus-visible:ring-ring/50 rounded-full border px-3 py-1 text-xs focus-visible:ring-3 focus-visible:outline-none';
	const thClass = 'px-3 py-2 text-left font-medium';
</script>

<svelte:window onkeydown={onWindowKey} />

<h1 class="mb-5 text-[28px] leading-tight font-[650] tracking-[-0.8px]">{tx('dms.title')}</h1>

{#if workspace.can('dms.document.create')}
	<UploadPanel tenant={tenantId} onSettled={refreshAfterUpload} />
{/if}

<section aria-labelledby="dms-list-title" class="space-y-3">
	<h2 id="dms-list-title" class="sr-only">{tx('dms.list.title')}</h2>

	<form
		role="search"
		class="flex flex-wrap gap-2"
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
	<p class="text-muted-foreground text-xs">{tx('dms.search.shortcuts')}</p>

	<div class="flex flex-wrap items-center gap-2" role="group" aria-label={tx('dms.preset.label')} data-testid="dms-presets">
		<span class="text-muted-foreground text-xs">{tx('dms.preset.label')}</span>
		{#each [['today', 'dms.preset.today'], ['week', 'dms.preset.week'], ['month', 'dms.preset.month'], ['year', 'dms.preset.year']] as const as [key, label] (key)}
			<button type="button" class={presetClass} aria-pressed={preset === key} onclick={() => applyPreset(key)} data-testid={`dms-preset-${key}`}>{tx(label)}</button>
		{/each}
		<button type="button" class={presetClass} aria-pressed={!f.from && !f.to} onclick={() => applyPreset(null)} data-testid="dms-preset-all">{tx('dms.preset.all')}</button>
		{#if hasAnyFilter(f)}
			<Button
				type="button"
				variant="ghost"
				size="sm"
				class="ml-auto"
				onclick={() => setParams({ q: null, type: null, corr: null, tags: null, from: null, to: null, trash: null, kind: null, min: null, max: null, cur: null, due: null, sort: null, order: null, open: null })}
				data-testid="dms-filter-reset"
			>
				{tx('dms.filter.reset')}
			</Button>
		{/if}
	</div>

	<div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-5" data-testid="dms-quickfilters">
		<label class="text-sm">
			<span class="mb-1 block">{tx('dms.filter.kind')}</span>
			<select class={selectClass} value={f.kind} onchange={(e) => setParams({ kind: e.currentTarget.value })} data-testid="dms-filter-kind">
				<option value="">{tx('dms.filter.all')}</option>
				{#each KINDS as kind (kind)}<option value={kind}>{tx(KIND_LABEL[kind])}</option>{/each}
			</select>
		</label>
		<label class="text-sm">
			<span class="mb-1 block">{tx('dms.filter.amountMin')}</span>
			<Input type="text" inputmode="decimal" value={f.min} aria-invalid={minInvalid} onchange={(e) => commitAmount('min', e.currentTarget.value)} data-testid="dms-filter-min" />
		</label>
		<label class="text-sm">
			<span class="mb-1 block">{tx('dms.filter.amountMax')}</span>
			<Input type="text" inputmode="decimal" value={f.max} aria-invalid={maxInvalid} onchange={(e) => commitAmount('max', e.currentTarget.value)} data-testid="dms-filter-max" />
		</label>
		<label class="text-sm">
			<span class="mb-1 block">{tx('dms.filter.due')}</span>
			<select class={selectClass} value={f.due} onchange={(e) => setParams({ due: e.currentTarget.value })} data-testid="dms-filter-due">
				<option value="">{tx('dms.filter.all')}</option>
				<option value="overdue">{tx('dms.filter.due.overdue')}</option>
				<option value="week">{tx('dms.filter.due.week')}</option>
				<option value="due">{tx('dms.filter.due.due')}</option>
			</select>
		</label>
		<label class="text-sm">
			<span class="mb-1 block">{tx('dms.sort.label')}</span>
			<select class={selectClass} value={sortValue} onchange={(e) => onSortSelect(e.currentTarget.value)} data-testid="dms-sort">
				{#each SORT_OPTIONS as [value, label] (value)}<option {value}>{tx(label)}</option>{/each}
			</select>
		</label>
	</div>
	{#if minInvalid || maxInvalid}
		<p role="alert" class="text-destructive text-xs" data-testid="dms-amount-invalid">{tx('dms.filter.amountInvalid')}</p>
	{/if}

	<details class="rounded-md border p-3" open={detailsOpen} data-testid="dms-filters">
		<summary class="cursor-pointer text-sm font-medium">{tx('dms.filter.more')}</summary>
		<div class="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
			<label class="text-sm">
				<span class="mb-1 block">{tx('dms.field.type')}</span>
				<select class={selectClass} value={f.type} onchange={(e) => setParams({ type: e.currentTarget.value })} data-testid="dms-filter-type">
					<option value="">{tx('dms.filter.all')}</option>
					{#each masters.types as type (type.id)}<option value={type.id}>{type.name}</option>{/each}
				</select>
			</label>
			<label class="text-sm">
				<span class="mb-1 block">{tx('dms.filter.sender')}</span>
				<select class={selectClass} value={f.corr} onchange={(e) => setParams({ corr: e.currentTarget.value })} data-testid="dms-filter-corr">
					<option value="">{tx('dms.filter.all')}</option>
					{#each masters.contacts as contact (contact.id)}<option value={contact.id}>{contact.name}</option>{/each}
				</select>
			</label>
			<label class="text-sm">
				<span class="mb-1 block">{tx('dms.filter.currency')}</span>
				<Input type="text" maxlength={3} value={f.cur} placeholder="EUR" onchange={(e) => setParams({ cur: e.currentTarget.value.trim().toUpperCase() })} data-testid="dms-filter-cur" />
			</label>
			<label class="text-sm">
				<span class="mb-1 block">{tx('dms.filter.dateFrom')}</span>
				<Input type="date" value={f.from} onchange={(e) => setParams({ from: e.currentTarget.value })} data-testid="dms-filter-from" />
			</label>
			<label class="text-sm">
				<span class="mb-1 block">{tx('dms.filter.dateTo')}</span>
				<Input type="date" value={f.to} onchange={(e) => setParams({ to: e.currentTarget.value })} data-testid="dms-filter-to" />
			</label>
		</div>
		<p class="text-muted-foreground mt-1 text-xs">{tx(listRoute ? 'dms.filter.dateHintList' : 'dms.filter.dateHintSearch')}</p>
		{#if masters.tags.length > 0}
			<fieldset class="mt-3">
				<legend class="mb-1 text-sm">{tx('dms.field.tags')}</legend>
				<div class="flex flex-wrap gap-x-4 gap-y-1">
					{#each masters.tags as tag (tag.id)}
						<label class="flex items-center gap-2 text-sm">
							<input type="checkbox" checked={f.tags.includes(tag.id)} onchange={() => toggleTag(tag.id)} data-testid={`dms-filter-tag-${tag.name}`} />
							{tag.name}
						</label>
					{/each}
				</div>
			</fieldset>
		{/if}
		<div class="mt-3 flex flex-wrap items-center justify-between gap-2">
			<div class="flex flex-wrap gap-x-5 gap-y-1">
				{#if canSuggestions}
					<label class="flex items-center gap-2 text-sm">
						<input type="checkbox" checked={f.open} onchange={(e) => setParams({ open: e.currentTarget.checked ? '1' : null })} data-testid="dms-filter-open" />
						{tx('dms.filter.openSuggestions')}
					</label>
				{/if}
				<label class="flex items-center gap-2 text-sm">
					<input type="checkbox" checked={f.trash} onchange={(e) => setParams({ trash: e.currentTarget.checked ? '1' : null })} data-testid="dms-trash-toggle" />
					{tx('dms.filter.trash')}
				</label>
			</div>
		</div>
		{#if f.open && suggestionsCapped}<p class="text-muted-foreground mt-2 text-xs">{tx('dms.filter.openCapped')}</p>{/if}
	</details>

	{#if listRoute}
		<p class="text-muted-foreground text-xs" data-testid="dms-list-route-hint">{tx(f.q ? 'dms.filter.listRouteQ' : 'dms.filter.listRoute')}</p>
	{/if}

	{#if facetGroups.length > 0}
		<div class="space-y-2" data-testid="dms-facets">
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

	<p role="status" aria-live="polite" class="text-muted-foreground text-sm" data-testid="dms-count">
		{#if loading && visibleRows.length === 0}
			{tx('common.loading')}
		{:else if f.trash}
			{tx('dms.list.countTrash', { count: visibleRows.length })}
		{:else}
			{tx(searching ? 'dms.list.countHits' : 'dms.list.count', { count: visibleRows.length })}
		{/if}
	</p>

	{#if !loading && visibleRows.length === 0 && !error}
		<p class="text-muted-foreground rounded-md border p-6 text-center" data-testid="dms-empty">
			{#if searching}{tx('dms.list.noHits', { query: f.q })}{:else if f.trash}{tx('dms.list.trashEmpty')}{:else if hasAnyFilter(f)}{tx('dms.list.noMatch')}{:else}{tx('dms.list.empty')}{/if}
		</p>
	{/if}

	{#if visibleRows.length > 0}
		<div class="overflow-x-auto rounded-lg border">
			<!-- Roving tabindex: one tab stop for the table, arrow keys inside (AK-F4-3). -->
			<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
			<table bind:this={tableEl} class="w-full text-sm" aria-label={tx('dms.list.title')} onkeydown={onTableKey} data-testid="dms-list">
				<thead class="bg-muted/50 text-muted-foreground text-xs">
					<tr>
						<th scope="col" class={thClass}>{tx('dms.col.kind')}</th>
						<th scope="col" class={thClass}>{tx('dms.col.title')}</th>
						{#each [['date', 'dms.col.date', 'hidden md:table-cell'], ['amount', 'dms.col.amount', 'hidden text-right md:table-cell'], ['due', 'dms.col.due', 'hidden lg:table-cell']] as const as [key, label, cls] (key)}
							<th scope="col" class="{thClass} {cls}" aria-sort={ariaSort(key)}>
								<button type="button" class="hover:text-foreground focus-visible:ring-ring/50 inline-flex items-center gap-1 rounded-sm font-medium focus-visible:ring-3 focus-visible:outline-none" onclick={() => cycleSort(key)} data-testid={`dms-sort-${key}`}>
									{tx(label)}
									{#if f.sort === key}
										{#if f.order === 'asc'}<ArrowUp class="size-3" aria-hidden="true" />{:else}<ArrowDown class="size-3" aria-hidden="true" />{/if}
									{/if}
								</button>
							</th>
						{/each}
						<th scope="col" class="{thClass} hidden lg:table-cell">{tx('dms.col.reference')}</th>
						<th scope="col" class={thClass}>{tx('dms.col.status')}</th>
					</tr>
				</thead>
				<tbody>
					{#each visibleRows as row, index (row.id)}
						{@const ex = extractionOf(row)}
						{@const date = row.doc_date ?? ex?.extracted_date}
						{@const money = formatMoney(ex?.amount, ex?.currency, i18n.locale)}
						{@const overdue = isOverdue(ex?.due_date, today) && !f.trash}
						<tr class="hover:bg-muted/40 border-t align-top" data-testid="dms-row">
							<td class="px-3 py-2">
								{#if ex}<KindBadge kind={ex.kind} certain={ex.kind_certain} />{:else}<span class="text-muted-foreground" data-testid="dms-row-nokind">–</span>{/if}
							</td>
							<td class="min-w-0 px-3 py-2 break-words">
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
									{#if row.correspondent_id}<span data-testid="dms-row-sender">{nameOf(masters.contacts, row.correspondent_id)}</span>{/if}
									{#if row.document_type_id}<span>{nameOf(masters.types, row.document_type_id)}</span>{/if}
									{#if row.asn}<span>{tx('dms.field.asn')} {row.asn}</span>{/if}
								</p>
								<p class="text-muted-foreground mt-0.5 flex flex-wrap gap-x-3 text-xs lg:hidden">
									{#if date}<span>{formatDate(date, i18n.locale)}</span>{/if}
									{#if money}<span>{money}</span>{/if}
									{#if ex?.due_date}<span class={overdue ? 'text-destructive font-medium' : ''}>{tx('dms.col.due')} {formatDate(ex.due_date, i18n.locale)}</span>{/if}
									{#if ex?.reference}<span>{ex.reference}</span>{/if}
								</p>
								{#if row.snippet}
									<!-- Snippet markers become <mark>; the text itself is inserted as text, never as HTML. -->
									<p class="mt-1 text-sm" data-testid="dms-snippet">
										{#each parseSnippet(row.snippet) as part, i (i)}{#if part.mark}<mark class="rounded-sm bg-amber-200 px-0.5 text-black dark:bg-amber-400">{part.text}</mark>{:else}{part.text}{/if}{/each}
									</p>
								{/if}
							</td>
							<td class="hidden px-3 py-2 whitespace-nowrap md:table-cell" data-testid="dms-row-date">{date ? formatDate(date, i18n.locale) : '–'}</td>
							<td class="hidden px-3 py-2 text-right whitespace-nowrap tabular-nums md:table-cell" data-testid="dms-row-amount">{money || '–'}</td>
							<td class="hidden px-3 py-2 whitespace-nowrap lg:table-cell" data-testid="dms-row-due">
								{#if ex?.due_date}
									<span class={overdue ? 'text-destructive font-medium' : ''}>{formatDate(ex.due_date, i18n.locale)}</span>
									{#if overdue}<span class="text-destructive block text-xs">{tx('dms.due.overdue')}</span>{/if}
								{:else}–{/if}
							</td>
							<td class="hidden px-3 py-2 break-all lg:table-cell" data-testid="dms-row-reference">{ex?.reference || '–'}</td>
							<td class="px-3 py-2">
								{#if isQuarantined(processing[row.id])}
									<span class="text-destructive font-medium" data-testid="dms-row-quarantine">{tx('dms.status.quarantine')}</span>
								{:else if processing[row.id] && !isProcessingOver(processing[row.id])}
									<span data-testid="dms-row-status">{tx('dms.status.processing')}</span>
								{:else}
									<span data-testid="dms-row-status">{tx(statusText[row.status])}</span>
								{/if}
								{#if (suggestionCount[row.id] ?? 0) > 0}
									<span class="bg-secondary text-secondary-foreground mt-1 block w-fit rounded-md px-1.5 py-0.5 text-xs" data-testid="dms-row-suggestions">
										{tx('dms.row.suggestions', { count: suggestionCount[row.id] })}
									</span>
								{/if}
							</td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
	{/if}

	{#if nextCursor}
		<div class="text-center">
			<Button type="button" variant="outline" disabled={loading} onclick={() => load(false)} data-testid="dms-more">{tx('dms.list.more')}</Button>
		</div>
	{/if}
</section>
