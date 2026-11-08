<script lang="ts">
	import { dmsAdminApi, dmsApi, dmsSourcesApi } from '#lib/api/client';
	import * as Card from '#lib/components/ui/card';
	import { tx } from '#lib/i18n/index.svelte';
	import { workspace } from '#lib/workspace.svelte';
	import { P } from './permissions';

	/**
	 * Dashboard card "Processing" (WP-F5b). Only counts the existing routes offer: documents in processing and to review
	 * (`documents?status=…&count=true`), open suggestions, sources whose last run failed. The backend has no route that counts
	 * quarantined (permanently failed) documents; a failed OCR run therefore only shows up as "in processing" here.
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

	async function count(read: () => Promise<number | null | undefined>): Promise<number | null> {
		try {
			return (await read()) ?? null;
		} catch {
			return null; // a missing right or a failing route only hides that row
		}
	}

	async function load() {
		const [processing, review, suggestions, sourcesFailed] = await Promise.all([
			count(async () => (await dmsApi.documents(tenantId, { status: 'processing', count: true, limit: 1 })).total),
			count(async () => (await dmsApi.documents(tenantId, { status: 'needs_review', count: true, limit: 1 })).total),
			workspace.can(P.suggestionRead) ? count(async () => (await dmsAdminApi.suggestions(tenantId, { count: true, limit: 1 })).total) : Promise.resolve(null),
			workspace.can(P.sourceRead)
				? count(async () => (await dmsSourcesApi.list(tenantId)).items.filter((s) => s.enabled && s.last_status === 'error').length)
				: Promise.resolve(null)
		]);
		const next: Row[] = [];
		if (processing !== null) next.push({ id: 'processing', label: 'dms.card.processing', count: processing, href: '/dms' });
		if (review !== null) next.push({ id: 'review', label: 'dms.card.needsReview', count: review, href: '/dms' });
		if (suggestions !== null) next.push({ id: 'suggestions', label: 'dms.card.suggestions', count: suggestions, href: '/dms/review' });
		if (sourcesFailed !== null) next.push({ id: 'sources', label: 'dms.card.sourcesFailed', count: sourcesFailed, href: '/dms/sources', alert: sourcesFailed > 0 });
		rows = next;
		loaded = true;
	}
	void load();
</script>

{#if loaded && rows.length > 0}
	<Card.Root data-testid="dms-processing-card">
		<Card.Header><Card.Title><h2 class="text-lg font-semibold">{tx('dms.card.title')}</h2></Card.Title></Card.Header>
		<Card.Content>
			<dl class="grid grid-cols-[1fr_auto] gap-x-6 gap-y-1 text-sm">
				{#each rows as row (row.id)}
					<dt><a class="underline" href={row.href} data-testid={`dms-card-${row.id}-link`}>{tx(row.label)}</a></dt>
					<dd class={row.alert ? 'text-destructive font-medium' : 'font-medium'} data-testid={`dms-card-${row.id}`}>{row.count}</dd>
				{/each}
			</dl>
			<p class="text-muted-foreground mt-2 text-xs">{tx('dms.card.note')}</p>
		</Card.Content>
	</Card.Root>
{/if}
