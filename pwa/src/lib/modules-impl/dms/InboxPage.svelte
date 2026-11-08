<script lang="ts">
	import { ApiError, dmsAdminApi, dmsApi, dmsSourcesApi, type DmsDocument, type DmsProcessing, type DmsSource, type DmsSuggestion } from '#lib/api/client';
	import ErrorBanner from '#lib/components/app/ErrorBanner.svelte';
	import { Button } from '#lib/components/ui/button';
	import { formatDate, formatDateTime } from '#lib/format';
	import { errorMessage, i18n, tx } from '#lib/i18n/index.svelte';
	import { workspace } from '#lib/workspace.svelte';
	import KindBadge from './KindBadge.svelte';
	import { loadMasters, type Masters } from './masters';
	import { addDays, formatMoney, isOverdue, localToday } from './overview';
	import { P } from './permissions';
	import SuggestionCard from './SuggestionCard.svelte';
	import { targetMissing } from './suggestion';
	import { isQuarantined } from './upload.svelte';
	import UploadPanel from './UploadPanel.svelte';

	/**
	 * "Heute / Eingang" (WP-F4c): what arrived and what needs attention, with direct actions. Built from existing routes only:
	 * latest documents, open suggestions (accept/reject), documents in processing whose run failed (restart), due dates
	 * (`due_to`), and sources whose last run failed. Quarantined documents are not listable by the backend; they are found among
	 * the documents still in processing.
	 */
	let { tenant }: { tenant: string } = $props();
	// svelte-ignore state_referenced_locally
	const tenantId = tenant;

	const today = localToday();
	const canSuggestions = $derived(workspace.can(P.suggestionRead));
	const canDecide = $derived(workspace.can(P.suggestionDecide));
	const canUpdate = $derived(workspace.can(P.documentUpdate));
	const canSources = $derived(workspace.can(P.sourceRead));

	let masters = $state<Masters>({ types: [], tags: [], fields: [], paths: [], contacts: [] });
	let recent = $state<DmsDocument[]>([]);
	let suggestions = $state<DmsSuggestion[]>([]);
	let suggestionTotal = $state<number | null>(null);
	let failed = $state<{ doc: DmsDocument; processing: DmsProcessing }[]>([]);
	let sourcesFailing = $state<DmsSource[]>([]);
	let due = $state<DmsDocument[]>([]);
	let loaded = $state(false);
	let errors = $state<Record<string, string>>({});
	let actionError = $state<string | null>(null);
	let busyId = $state<string | null>(null);
	let staleIds = $state<Set<string>>(new Set());

	async function guarded<T>(key: string, run: () => Promise<T>, apply: (value: T) => void) {
		try {
			apply(await run());
			delete errors[key];
		} catch (e) {
			errors[key] = errorMessage(e);
		}
	}

	async function loadFailed() {
		const processingDocs = await dmsApi.documents(tenantId, { status: 'processing', limit: 20 });
		const result: { doc: DmsDocument; processing: DmsProcessing }[] = [];
		await Promise.all(
			processingDocs.items.map(async (doc) => {
				try {
					const processing = await dmsApi.processing(tenantId, doc.id);
					if (isQuarantined(processing)) result.push({ doc, processing });
				} catch {
					// a missing marker only hides that document
				}
			})
		);
		failed = result;
	}

	async function load() {
		void loadMasters(tenantId).then((m) => (masters = m));
		await Promise.all([
			guarded('recent', () => dmsApi.documents(tenantId, { sort: 'created_at', order: 'desc', limit: 8 }), (r) => (recent = r.items)),
			guarded('due', () => dmsApi.documents(tenantId, { due_to: addDays(today, 7), sort: 'due_date', order: 'asc', limit: 8 }), (r) => (due = r.items)),
			guarded('failed', loadFailed, () => {}),
			canSuggestions ? guarded('suggestions', () => dmsAdminApi.suggestions(tenantId, { state: 'open', limit: 5, count: true }), (r) => ((suggestions = r.items), (suggestionTotal = r.total ?? r.items.length))) : Promise.resolve(),
			canSources ? guarded('sources', () => dmsSourcesApi.list(tenantId), (r) => (sourcesFailing = r.items.filter((s) => s.last_status === 'error'))) : Promise.resolve()
		]);
		loaded = true;
	}
	void load();

	async function decide(s: DmsSuggestion, how: 'accept' | 'reject') {
		busyId = s.id;
		actionError = null;
		try {
			if (how === 'accept') await dmsAdminApi.acceptSuggestion(tenantId, s.id);
			else await dmsAdminApi.rejectSuggestion(tenantId, s.id);
			// Reload the list so the next open suggestion moves up and the count stays right.
			await guarded('suggestions', () => dmsAdminApi.suggestions(tenantId, { state: 'open', limit: 5, count: true }), (r) => ((suggestions = r.items), (suggestionTotal = r.total ?? r.items.length)));
		} catch (e) {
			if (e instanceof ApiError && e.code === 'suggestion_stale') staleIds = new Set([...staleIds, s.id]);
			else actionError = errorMessage(e);
		} finally {
			busyId = null;
		}
	}

	async function restart(id: string) {
		busyId = id;
		actionError = null;
		try {
			await dmsApi.retryProcessing(tenantId, id);
			failed = failed.filter((x) => x.doc.id !== id);
		} catch (e) {
			actionError = errorMessage(e);
		} finally {
			busyId = null;
		}
	}

	const statusText = { processing: 'dms.status.processing', needs_review: 'dms.status.needsReview', archived: 'dms.status.archived' } as const;
	const sectionClass = 'rounded-lg border p-4';
	const needsAttention = $derived(suggestions.length + failed.length + sourcesFailing.length + due.length);
</script>

<h1 class="mb-1 text-[28px] leading-tight font-[650] tracking-[-0.8px]">{tx('dms.inbox.title')}</h1>
<p class="text-muted-foreground mb-4 text-sm">{tx('dms.inbox.intro', { date: formatDate(today, i18n.locale) })}</p>

{#if workspace.can('dms.document.create')}
	<UploadPanel tenant={tenantId} onSettled={() => void load()} />
{/if}

<ErrorBanner message={actionError} />
{#each Object.values(errors) as message (message)}<ErrorBanner {message} />{/each}

{#if !loaded}
	<p class="text-muted-foreground text-sm">{tx('common.loading')}</p>
{:else}
	<div class="grid gap-4 lg:grid-cols-2">
		<section class="{sectionClass} lg:col-span-2" aria-labelledby="inbox-attention" data-testid="inbox-attention">
			<h2 id="inbox-attention" class="mb-3 text-lg font-medium">{tx('dms.inbox.attention')}</h2>
			{#if needsAttention === 0}
				<p class="text-muted-foreground text-sm" data-testid="inbox-attention-empty">{tx('dms.inbox.attentionEmpty')}</p>
			{/if}

			{#if suggestions.length > 0}
				<div class="mb-4" data-testid="inbox-suggestions">
					<div class="mb-2 flex flex-wrap items-baseline justify-between gap-2">
						<h3 class="text-sm font-medium">{tx('dms.inbox.suggestions', { count: suggestionTotal ?? suggestions.length })}</h3>
						<a href="/dms/review" class="text-sm underline-offset-2 hover:underline">{tx('dms.inbox.reviewAll')}</a>
					</div>
					<ul class="space-y-2">
						{#each suggestions as s (s.id)}
							<li class="rounded-md border p-3" data-testid="inbox-suggestion">
								<SuggestionCard
									suggestion={s}
									{masters}
									stale={staleIds.has(s.id) || targetMissing(s, masters)}
									canDecide={canDecide}
									busy={busyId === s.id}
									onaccept={() => decide(s, 'accept')}
									onreject={() => decide(s, 'reject')}
								/>
							</li>
						{/each}
					</ul>
				</div>
			{/if}

			{#if failed.length > 0}
				<div class="mb-4" data-testid="inbox-failed">
					<h3 class="mb-2 text-sm font-medium">{tx('dms.inbox.failed', { count: failed.length })}</h3>
					<ul class="space-y-2">
						{#each failed as item (item.doc.id)}
							<li class="flex flex-wrap items-center justify-between gap-2 rounded-md border p-3" data-testid="inbox-failed-item">
								<span class="min-w-0 break-words">
									<a href={`/dms/${item.doc.id}`} class="font-medium underline-offset-2 hover:underline">{item.doc.title}</a>
									<span class="text-destructive ml-2 text-xs">{tx('dms.status.quarantine')} ({item.processing.error_code ?? ''})</span>
								</span>
								{#if canUpdate}
									<Button type="button" size="sm" variant="outline" disabled={busyId === item.doc.id} onclick={() => restart(item.doc.id)} data-testid="inbox-restart">
										{tx('dms.processing.retry')}
									</Button>
								{/if}
							</li>
						{/each}
					</ul>
				</div>
			{/if}

			{#if sourcesFailing.length > 0}
				<div class="mb-4" data-testid="inbox-sources">
					<h3 class="mb-2 text-sm font-medium">{tx('dms.inbox.sources', { count: sourcesFailing.length })}</h3>
					<ul class="space-y-1 text-sm">
						{#each sourcesFailing as source (source.id)}
							<li>
								<a href="/dms/sources" class="font-medium underline-offset-2 hover:underline">{source.name}</a>
								<span class="text-destructive ml-2 text-xs">{source.last_error ?? ''}</span>
							</li>
						{/each}
					</ul>
				</div>
			{/if}

			{#if due.length > 0}
				<div data-testid="inbox-due">
					<div class="mb-2 flex flex-wrap items-baseline justify-between gap-2">
						<h3 class="text-sm font-medium">{tx('dms.inbox.due')}</h3>
						<a href="/dms?due=week" class="text-sm underline-offset-2 hover:underline">{tx('dms.inbox.dueAll')}</a>
					</div>
					<ul class="divide-y rounded-md border">
						{#each due as doc (doc.id)}
							{@const overdue = isOverdue(doc.extraction?.due_date, today)}
							<li class="flex flex-wrap items-center justify-between gap-x-4 gap-y-1 p-3 text-sm" data-testid="inbox-due-item">
								<span class="min-w-0 break-words">
									{#if doc.extraction}<KindBadge kind={doc.extraction.kind} certain={doc.extraction.kind_certain} />{/if}
									<a href={`/dms/${doc.id}`} class="ml-1 font-medium underline-offset-2 hover:underline">{doc.title}</a>
								</span>
								<span class="flex flex-wrap items-center gap-3">
									<span class="tabular-nums">{formatMoney(doc.extraction?.amount, doc.extraction?.currency, i18n.locale)}</span>
									<span class={overdue ? 'text-destructive font-medium' : ''}>
										{tx('dms.col.due')} {formatDate(doc.extraction?.due_date, i18n.locale)}{#if overdue} ({tx('dms.due.overdue')}){/if}
									</span>
								</span>
							</li>
						{/each}
					</ul>
				</div>
			{/if}
		</section>

		<section class="{sectionClass} lg:col-span-2" aria-labelledby="inbox-recent" data-testid="inbox-recent">
			<div class="mb-3 flex flex-wrap items-baseline justify-between gap-2">
				<h2 id="inbox-recent" class="text-lg font-medium">{tx('dms.inbox.recent')}</h2>
				<a href="/dms" class="text-sm underline-offset-2 hover:underline">{tx('dms.inbox.allDocuments')}</a>
			</div>
			{#if recent.length === 0}
				<p class="text-muted-foreground text-sm" data-testid="inbox-recent-empty">{tx('dms.list.empty')}</p>
			{:else}
				<ul class="divide-y rounded-md border">
					{#each recent as doc (doc.id)}
						<li class="flex flex-wrap items-center justify-between gap-x-4 gap-y-1 p-3 text-sm" data-testid="inbox-recent-item">
							<span class="min-w-0 break-words">
								{#if doc.extraction}<KindBadge kind={doc.extraction.kind} certain={doc.extraction.kind_certain} />{/if}
								<a href={`/dms/${doc.id}`} class="ml-1 font-medium underline-offset-2 hover:underline">{doc.title}</a>
							</span>
							<span class="text-muted-foreground flex flex-wrap gap-x-3 text-xs">
								{#if doc.extraction?.amount}<span class="tabular-nums">{formatMoney(doc.extraction.amount, doc.extraction.currency, i18n.locale)}</span>{/if}
								<span>{formatDateTime(doc.received_at, i18n.locale)}</span>
								<span>{tx(statusText[doc.status])}</span>
							</span>
						</li>
					{/each}
				</ul>
			{/if}
		</section>
	</div>
{/if}
