<script lang="ts">
	import { tick } from 'svelte';
	import { goto } from '$app/navigation';
	import { ApiError, dmsAdminApi, type DmsRule, type DmsSuggestion } from '#lib/api/client';
	import ErrorBanner from '#lib/components/app/ErrorBanner.svelte';
	import { Button } from '#lib/components/ui/button';
	import { errorMessage, tx } from '#lib/i18n/index.svelte';
	import { workspace } from '#lib/workspace.svelte';
	import { loadMasters, type Masters } from './masters';
	import { P } from './permissions';
	import SuggestionCard from './SuggestionCard.svelte';
	import { KIND_TEXT, sameId, targetMissing } from './suggestion';

	let { tenant }: { tenant: string } = $props();
	// The page is re-keyed on tenant switch, so the tenant is fixed for the lifetime of this component.
	// svelte-ignore state_referenced_locally
	const tenantId = tenant;

	const canDecide = $derived(workspace.can(P.suggestionDecide));
	const kinds = Object.keys(KIND_TEXT) as (keyof typeof KIND_TEXT)[];

	let masters = $state<Masters>({ types: [], tags: [], fields: [], paths: [], contacts: [] });
	let rules = $state<DmsRule[]>([]);
	let items = $state<DmsSuggestion[]>([]);
	let nextCursor = $state<string | null>(null);
	let total = $state<number | null>(null);
	let loading = $state(true);
	let error = $state<string | null>(null);
	let kind = $state('');
	let active = $state(0);
	let busyId = $state<string | null>(null);
	/** Ids whose accept failed with 409 suggestion_stale (the backend decides; the row stays so it can be rejected). */
	let staleIds = $state<Set<string>>(new Set());
	let announcement = $state('');
	let listEl = $state<HTMLUListElement | null>(null);
	let seq = 0;

	const ruleName = (s: DmsSuggestion) => rules.find((r) => sameId(r.id, s.rule_id))?.name ?? null;
	const isStale = (s: DmsSuggestion) => staleIds.has(s.id) || targetMissing(s, masters);

	async function load(reset: boolean) {
		const mine = ++seq;
		loading = true;
		error = null;
		try {
			const page = await dmsAdminApi.suggestions(tenantId, {
				state: 'open',
				kind: kind || undefined,
				cursor: reset ? null : nextCursor,
				limit: 25,
				count: true
			});
			if (mine !== seq) return;
			items = reset ? page.items : [...items, ...page.items];
			nextCursor = page.next_cursor;
			total = page.total ?? null;
			if (reset) active = 0;
		} catch (e) {
			if (mine === seq) error = errorMessage(e);
		} finally {
			if (mine === seq) loading = false;
		}
	}

	void loadMasters(tenantId).then((m) => (masters = m));
	if (workspace.can(P.ruleRead)) void dmsAdminApi.rules(tenantId).then((p) => (rules = p.items), () => undefined);
	void load(true);

	function changeKind(event: Event) {
		kind = (event.currentTarget as HTMLSelectElement).value;
		void load(true);
	}

	async function focusRow(index: number) {
		active = Math.max(0, Math.min(items.length - 1, index));
		await tick();
		(listEl?.querySelectorAll<HTMLElement>('[data-row-link]')[active] ?? null)?.focus();
	}

	async function decide(s: DmsSuggestion, how: 'accept' | 'reject') {
		if (!canDecide || busyId) return;
		busyId = s.id;
		error = null;
		const label = `${s.document_title}: ${tx(KIND_TEXT[s.kind])}`;
		try {
			if (how === 'accept') await dmsAdminApi.acceptSuggestion(tenantId, s.id);
			else await dmsAdminApi.rejectSuggestion(tenantId, s.id);
			const index = items.findIndex((x) => x.id === s.id);
			items = items.filter((x) => x.id !== s.id);
			if (total !== null) total = Math.max(0, total - 1);
			announcement = tx(how === 'accept' ? 'dms.review.announce.accepted' : 'dms.review.announce.rejected', { item: label });
			await focusRow(Math.min(index, items.length - 1));
		} catch (e) {
			if (e instanceof ApiError && e.code === 'suggestion_stale') {
				staleIds = new Set([...staleIds, s.id]);
				announcement = tx('dms.suggestion.stale');
			} else if (e instanceof ApiError && e.code === 'suggestion_decided') {
				// Somebody else decided in the meantime: the row is obsolete.
				items = items.filter((x) => x.id !== s.id);
				error = errorMessage(e);
			} else error = errorMessage(e);
		} finally {
			busyId = null;
		}
	}

	/** Keyboard workflow: J/K or arrows move, A accepts, R rejects, E opens the document to change the value. */
	function onKeydown(event: KeyboardEvent) {
		if (event.ctrlKey || event.metaKey || event.altKey) return;
		const target = event.target as HTMLElement;
		if (['INPUT', 'TEXTAREA', 'SELECT'].includes(target.tagName)) return;
		const current = items[active];
		const key = event.key.toLowerCase();
		if (key === 'arrowdown' || key === 'j') void focusRow(active + 1);
		else if (key === 'arrowup' || key === 'k') void focusRow(active - 1);
		else if (key === 'home') void focusRow(0);
		else if (key === 'end') void focusRow(items.length - 1);
		else if (current && key === 'a') void decide(current, 'accept');
		else if (current && key === 'r') void decide(current, 'reject');
		else if (current && key === 'e') void goto(`/dms/${current.document_id}`);
		else return;
		event.preventDefault();
	}
</script>

<h1 class="mb-1 text-2xl font-semibold" data-testid="review-title">{tx('dms.review.title')}</h1>
<p class="text-muted-foreground mb-4 text-sm">{tx('dms.review.intro')}</p>

<ErrorBanner message={error} />

<div class="mb-3 flex flex-wrap items-end gap-3">
	<label class="text-sm">
		<span class="mb-1 block">{tx('dms.review.filterKind')}</span>
		<select class="border-input bg-background h-8 rounded-lg border px-2 text-sm" value={kind} onchange={changeKind} data-testid="review-kind">
			<option value="">{tx('dms.filter.all')}</option>
			{#each kinds as k (k)}<option value={k}>{tx(KIND_TEXT[k])}</option>{/each}
		</select>
	</label>
	<p class="text-muted-foreground text-sm" data-testid="review-count">{tx('dms.review.count', { count: total ?? items.length })}</p>
</div>

<p class="text-muted-foreground mb-3 text-xs" data-testid="review-shortcuts">{tx('dms.review.shortcuts')}</p>
<p class="sr-only" role="status" data-testid="review-announce">{announcement}</p>

{#if loading && items.length === 0}
	<p class="text-muted-foreground text-sm">{tx('common.loading')}</p>
{:else if items.length === 0 && !error}
	<p class="text-muted-foreground" data-testid="review-empty">{tx('dms.review.empty')}</p>
{:else}
	<!-- svelte-ignore a11y_no_noninteractive_element_interactions -->
	<ul bind:this={listEl} class="space-y-2" aria-label={tx('dms.review.listLabel')} onkeydown={onKeydown} data-testid="review-list">
		{#each items as s, i (s.id)}
			<li
				data-testid="review-row"
				data-state={isStale(s) ? 'stale' : 'open'}
				class="focus-within:border-ring rounded-lg border p-3 data-[active=true]:bg-muted/40"
				data-active={i === active}
				onfocusin={() => (active = i)}
			>
				<SuggestionCard
					suggestion={s}
					{masters}
					ruleName={ruleName(s)}
					stale={isStale(s)}
					{canDecide}
					tabbable={i === active}
					busy={busyId === s.id}
					onaccept={() => decide(s, 'accept')}
					onreject={() => decide(s, 'reject')}
				/>
			</li>
		{/each}
	</ul>
	{#if nextCursor}
		<Button type="button" variant="outline" class="mt-3" disabled={loading} onclick={() => load(false)} data-testid="review-more">{tx('dms.list.more')}</Button>
	{/if}
{/if}
