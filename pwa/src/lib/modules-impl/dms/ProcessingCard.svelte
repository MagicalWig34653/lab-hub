<script lang="ts">
	import { dmsApi, dmsSourcesApi } from '#lib/api/client';
	import ChevronRight from '@lucide/svelte/icons/chevron-right';
	import * as Card from '#lib/components/ui/card';
	import { tx } from '#lib/i18n/index.svelte';
	import { workspace } from '#lib/workspace.svelte';
	import { localToday } from './overview';
	import { P } from './permissions';

	/**
	 * Dashboard card "Processing" (WP-F5b, WP-F4d). Counters come from `GET dms/stats` (WP-D9: in processing, quarantine, open suggestions,
	 * overdue, new in 7 days; `today` = local day); "to review" still counts through the document list, failed sources through the source list.
	 */
	let { tenant }: { tenant: string } = $props();
	// svelte-ignore state_referenced_locally
	const tenantId = tenant;

	interface Row {
		id: string;
		label: string;
		count: number;
		href: string;
		alert?: boolean;
	}
	let rows = $state<Row[]>([]);
	let loaded = $state(false);

	async function guarded<T>(read: () => Promise<T>): Promise<T | null> {
		try {
			return await read();
		} catch {
			return null; // a missing right or a failing route only hides that row
		}
	}

	async function load() {
		const [stats, review, sourcesFailed] = await Promise.all([
			guarded(() => dmsApi.stats(tenantId, localToday())),
			guarded(async () => (await dmsApi.documents(tenantId, { status: 'needs_review', count: true, limit: 1 })).total ?? null),
			workspace.can(P.sourceRead) ? guarded(async () => (await dmsSourcesApi.list(tenantId)).items.filter((s) => s.enabled && s.last_status === 'error').length) : Promise.resolve(null)
		]);
		const next: Row[] = [];
		if (stats) next.push({ id: 'processing', label: 'dms.card.processing', count: stats.queued, href: '/dms' });
		if (stats) next.push({ id: 'failed', label: 'dms.card.failed', count: stats.failed, href: '/dms/inbox', alert: stats.failed > 0 });
		if (review !== null) next.push({ id: 'review', label: 'dms.card.needsReview', count: review, href: '/dms' });
		if (stats) next.push({ id: 'suggestions', label: 'dms.card.suggestions', count: stats.open_suggestions, href: '/dms?open=1' });
		if (stats) next.push({ id: 'overdue', label: 'dms.card.overdue', count: stats.overdue, href: '/dms?due=overdue', alert: stats.overdue > 0 });
		if (stats) next.push({ id: 'new', label: 'dms.card.new', count: stats.new_last_7_days, href: '/dms/inbox' });
		if (sourcesFailed !== null) next.push({ id: 'sources', label: 'dms.card.sourcesFailed', count: sourcesFailed, href: '/dms/sources', alert: sourcesFailed > 0 });
		rows = next;
		loaded = true;
	}
	void load();
</script>

{#if loaded && rows.length > 0}
	<Card.Root data-testid="dms-processing-card">
		<Card.Header><Card.Title><h2 class="panel-title">{tx('dms.card.title')}</h2></Card.Title></Card.Header>
		<Card.Content>
			<ul class="divide-y">
				{#each rows as row (row.id)}
					<li>
						<a class="hover:bg-muted/60 -mx-2 flex min-h-11 items-center gap-3 rounded-md px-2 text-sm" href={row.href} data-testid={`dms-card-${row.id}-link`}>
							<span class="min-w-0 flex-1 break-words">{tx(row.label)}</span>
							<span
								class="tabular min-w-7 rounded-full px-2 py-0.5 text-center text-xs font-semibold {row.alert ? 'bg-destructive/10 text-destructive' : 'bg-muted'}"
								data-testid={`dms-card-${row.id}`}>{row.count}</span
							>
							<ChevronRight class="text-muted-foreground size-4 shrink-0" aria-hidden="true" />
						</a>
					</li>
				{/each}
			</ul>
		</Card.Content>
	</Card.Root>
{/if}
