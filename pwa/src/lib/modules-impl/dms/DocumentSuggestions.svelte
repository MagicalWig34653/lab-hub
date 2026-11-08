<script lang="ts">
	import { ApiError, dmsAdminApi, type DmsSuggestion } from '#lib/api/client';
	import ErrorBanner from '#lib/components/app/ErrorBanner.svelte';
	import { errorMessage, tx } from '#lib/i18n/index.svelte';
	import { workspace } from '#lib/workspace.svelte';
	import type { Masters } from './masters';
	import { P } from './permissions';
	import SuggestionCard from './SuggestionCard.svelte';
	import { targetMissing } from './suggestion';

	/** Open suggestions of one document on its detail page (same decisions as the review queue). */
	let {
		tenant,
		documentId,
		masters,
		disabled = false,
		onchanged
	}: { tenant: string; documentId: string; masters: Masters; disabled?: boolean; onchanged: () => void } = $props();
	// svelte-ignore state_referenced_locally
	const tenantId = tenant;
	// svelte-ignore state_referenced_locally
	const docId = documentId;

	const canDecide = $derived(workspace.can(P.suggestionDecide) && !disabled);

	let items = $state<DmsSuggestion[]>([]);
	let loaded = $state(false);
	let error = $state<string | null>(null);
	let busyId = $state<string | null>(null);
	let staleIds = $state<Set<string>>(new Set());

	async function load() {
		try {
			items = (await dmsAdminApi.documentSuggestions(tenantId, docId)).items;
			error = null;
		} catch (e) {
			error = errorMessage(e);
		} finally {
			loaded = true;
		}
	}
	void load();

	async function decide(s: DmsSuggestion, how: 'accept' | 'reject') {
		busyId = s.id;
		error = null;
		try {
			if (how === 'accept') await dmsAdminApi.acceptSuggestion(tenantId, s.id);
			else await dmsAdminApi.rejectSuggestion(tenantId, s.id);
			items = items.filter((x) => x.id !== s.id);
			if (how === 'accept') onchanged();
		} catch (e) {
			if (e instanceof ApiError && e.code === 'suggestion_stale') staleIds = new Set([...staleIds, s.id]);
			else error = errorMessage(e);
		} finally {
			busyId = null;
		}
	}
</script>

{#if loaded && (items.length > 0 || error)}
	<section class="mt-8" aria-labelledby="dms-suggestions-title" data-testid="dms-doc-suggestions">
		<h2 id="dms-suggestions-title" class="mb-2 text-lg font-medium">{tx('dms.suggestion.docTitle')}</h2>
		<ErrorBanner message={error} />
		<ul class="space-y-2">
			{#each items as s (s.id)}
				{@const stale = staleIds.has(s.id) || targetMissing(s, masters)}
				<li class="rounded-lg border p-3" data-testid="doc-suggestion" data-state={stale ? 'stale' : 'open'}>
					<SuggestionCard
						suggestion={s}
						{masters}
						{stale}
						{canDecide}
						busy={busyId === s.id}
						showDocument={false}
						onaccept={() => decide(s, 'accept')}
						onreject={() => decide(s, 'reject')}
					/>
				</li>
			{/each}
		</ul>
	</section>
{/if}
