<script lang="ts">
	import { dmsAdminApi, dmsApi, type DmsDocument, type DmsDuplicate } from '#lib/api/client';
	import ErrorBanner from '#lib/components/app/ErrorBanner.svelte';
	import { Button } from '#lib/components/ui/button';
	import { formatBytes, formatDate, formatDateTime } from '#lib/format';
	import { errorMessage, i18n, tx } from '#lib/i18n/index.svelte';
	import { workspace } from '#lib/workspace.svelte';
	import { loadMasters, nameOf, type Masters } from './masters';
	import { P } from './permissions';

	let { tenant }: { tenant: string } = $props();
	// svelte-ignore state_referenced_locally
	const tenantId = tenant;

	const canDecide = $derived(workspace.can(P.documentUpdate));
	const methodText = {
		sha256: 'dms.duplicates.method.sha256',
		text_hash: 'dms.duplicates.method.text_hash',
		similarity: 'dms.duplicates.method.similarity'
	} as const;
	const stateText = {
		open: 'dms.duplicates.state.open',
		confirmed: 'dms.duplicates.state.confirmed',
		dismissed: 'dms.duplicates.state.dismissed'
	} as const;

	let stateFilter = $state<'open' | 'confirmed' | 'dismissed' | 'all'>('open');
	let items = $state<DmsDuplicate[]>([]);
	let nextCursor = $state<string | null>(null);
	let loading = $state(true);
	let error = $state<string | null>(null);
	let busyId = $state<string | null>(null);
	let masters = $state<Masters>({ types: [], tags: [], fields: [], paths: [], contacts: [] });
	/** Loaded documents of an expanded comparison, by duplicate id. */
	let compare = $state<Record<string, { a: DmsDocument; b: DmsDocument } | 'loading' | 'error'>>({});
	let seq = 0;

	async function load(reset: boolean) {
		const mine = ++seq;
		loading = true;
		error = null;
		try {
			const page = await dmsAdminApi.duplicates(tenantId, { state: stateFilter, cursor: reset ? null : nextCursor, limit: 25 });
			if (mine !== seq) return;
			items = reset ? page.items : [...items, ...page.items];
			nextCursor = page.next_cursor;
		} catch (e) {
			if (mine === seq) error = errorMessage(e);
		} finally {
			if (mine === seq) loading = false;
		}
	}

	void loadMasters(tenantId).then((m) => (masters = m));
	void load(true);

	function changeState(event: Event) {
		stateFilter = (event.currentTarget as HTMLSelectElement).value as typeof stateFilter;
		compare = {};
		void load(true);
	}

	async function decide(d: DmsDuplicate, to: 'confirmed' | 'dismissed') {
		busyId = d.id;
		error = null;
		try {
			const updated = await dmsAdminApi.resolveDuplicate(tenantId, d.id, to);
			items = stateFilter === 'open' ? items.filter((x) => x.id !== d.id) : items.map((x) => (x.id === d.id ? updated : x));
		} catch (e) {
			error = errorMessage(e);
		} finally {
			busyId = null;
		}
	}

	async function toggleCompare(d: DmsDuplicate) {
		if (compare[d.id]) {
			delete compare[d.id];
			return;
		}
		compare[d.id] = 'loading';
		try {
			const [a, b] = await Promise.all([dmsApi.document(tenantId, d.document_id), dmsApi.document(tenantId, d.duplicate_of)]);
			compare[d.id] = { a, b };
		} catch {
			compare[d.id] = 'error';
		}
	}

	const rowsOf = (doc: DmsDocument) => {
		const file = doc.files?.find((f) => f.role === 'original');
		return [
			['dms.field.title', doc.title],
			['dms.field.date', formatDate(doc.doc_date, i18n.locale) || '–'],
			['dms.field.type', nameOf(masters.types, doc.document_type_id) || '–'],
			['dms.field.asn', doc.asn === null || doc.asn === undefined ? '–' : String(doc.asn)],
			['dms.field.received', formatDateTime(doc.received_at, i18n.locale)],
			['dms.field.file', file ? `${file.original_name ?? ''} · ${formatBytes(file.size_bytes, i18n.locale)}` : '–'],
			['dms.field.sha', file?.sha256 ?? '–']
		] as const;
	};
</script>

<h1 class="mb-1 text-2xl font-semibold" data-testid="duplicates-title">{tx('dms.duplicates.title')}</h1>
<p class="text-muted-foreground mb-4 text-sm">{tx('dms.duplicates.intro')}</p>
<ErrorBanner message={error} />

<label class="mb-4 block text-sm">
	<span class="mb-1 block">{tx('dms.duplicates.filterState')}</span>
	<select class="border-input bg-background h-8 rounded-lg border px-2 text-sm" value={stateFilter} onchange={changeState} data-testid="duplicates-state">
		<option value="open">{tx('dms.duplicates.state.open')}</option>
		<option value="confirmed">{tx('dms.duplicates.state.confirmed')}</option>
		<option value="dismissed">{tx('dms.duplicates.state.dismissed')}</option>
		<option value="all">{tx('dms.filter.all')}</option>
	</select>
</label>

{#if loading && items.length === 0}
	<p class="text-muted-foreground text-sm">{tx('common.loading')}</p>
{:else if items.length === 0 && !error}
	<p class="text-muted-foreground" data-testid="duplicates-empty">{tx('dms.duplicates.empty')}</p>
{:else}
	<ul class="space-y-3" data-testid="duplicates-list">
		{#each items as d (d.id)}
			{@const cmp = compare[d.id]}
			<li class="rounded-lg border p-3" data-testid="duplicate-row" data-state={d.state}>
				<div class="grid gap-3 sm:grid-cols-2">
					<div>
						<p class="text-muted-foreground text-xs">{tx('dms.duplicates.newer')}</p>
						<a class="font-medium break-words underline-offset-2 hover:underline" href={`/dms/${d.document_id}`} data-testid="duplicate-a">{d.document_title}</a>
					</div>
					<div>
						<p class="text-muted-foreground text-xs">{tx('dms.duplicates.older')}</p>
						<a class="font-medium break-words underline-offset-2 hover:underline" href={`/dms/${d.duplicate_of}`} data-testid="duplicate-b">{d.duplicate_of_title}</a>
					</div>
				</div>
				<p class="text-muted-foreground mt-2 text-xs" data-testid="duplicate-meta">
					{tx(methodText[d.method])} · {tx('dms.duplicates.score', { percent: Math.round(d.score * 100) })} · {tx(stateText[d.state])}
				</p>
				<div class="mt-2 flex flex-wrap gap-2">
					<Button type="button" size="sm" variant="outline" aria-expanded={cmp !== undefined} onclick={() => toggleCompare(d)} data-testid="duplicate-compare">
						{tx(cmp !== undefined ? 'dms.duplicates.hideCompare' : 'dms.duplicates.compare')}
					</Button>
					{#if canDecide && d.state === 'open'}
						<Button type="button" size="sm" disabled={busyId === d.id} onclick={() => decide(d, 'confirmed')} data-testid="duplicate-confirm">{tx('dms.duplicates.confirm')}</Button>
						<Button type="button" size="sm" variant="outline" disabled={busyId === d.id} onclick={() => decide(d, 'dismissed')} data-testid="duplicate-dismiss">{tx('dms.duplicates.dismiss')}</Button>
					{/if}
				</div>
				{#if cmp === 'loading'}
					<p class="text-muted-foreground mt-2 text-sm">{tx('common.loading')}</p>
				{:else if cmp === 'error'}
					<p class="text-destructive mt-2 text-sm" role="alert">{tx('dms.duplicates.compareError')}</p>
				{:else if cmp}
					{@const left = rowsOf(cmp.a)}
					{@const right = rowsOf(cmp.b)}
					<table class="mt-3 w-full text-left text-sm" data-testid="duplicate-table">
						<caption class="sr-only">{tx('dms.duplicates.compare')}</caption>
						<thead>
							<tr class="text-muted-foreground border-b">
								<th scope="col" class="py-1 pr-3"><span class="sr-only">{tx('dms.duplicates.property')}</span></th>
								<th scope="col" class="py-1 pr-3">{tx('dms.duplicates.newer')}</th>
								<th scope="col" class="py-1">{tx('dms.duplicates.older')}</th>
							</tr>
						</thead>
						<tbody>
							{#each left as [label, value], i (label)}
								<tr class="border-b" data-differs={value !== right[i][1]}>
									<th scope="row" class="text-muted-foreground py-1 pr-3 font-normal">{tx(label)}</th>
									<td class="py-1 pr-3 break-all">{value}</td>
									<td class="py-1 break-all">{right[i][1]}</td>
								</tr>
							{/each}
						</tbody>
					</table>
				{/if}
			</li>
		{/each}
	</ul>
	{#if nextCursor}
		<Button type="button" variant="outline" class="mt-3" disabled={loading} onclick={() => load(false)}>{tx('dms.list.more')}</Button>
	{/if}
{/if}
