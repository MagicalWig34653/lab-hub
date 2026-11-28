<script lang="ts">
	import { dmsApi, type DmsNote } from '#lib/api/client';
	import ErrorBanner from '#lib/components/app/ErrorBanner.svelte';
	import { formatDateTime } from '#lib/format';
	import { errorMessage, i18n, tx } from '#lib/i18n/index.svelte';

	/** Notes of a document (WP-PA2): read only, they come from the Paperless import. Rendered as text, never as markup. */
	let { tenant, documentId }: { tenant: string; documentId: string } = $props();
	// svelte-ignore state_referenced_locally
	const tenantId = tenant;
	// svelte-ignore state_referenced_locally
	const id = documentId;

	let notes = $state<DmsNote[]>([]);
	let error = $state<string | null>(null);

	dmsApi.notes(tenantId, id).then(
		(result) => (notes = result.items),
		(e) => (error = errorMessage(e))
	);
</script>

<ErrorBanner message={error} />
{#if notes.length > 0}
	<section class="mt-6" aria-labelledby="dms-notes-title" data-testid="dms-notes">
		<h2 id="dms-notes-title" class="panel-title mb-2">{tx('dms.notes.title')}</h2>
		<ul class="space-y-2">
			{#each notes as note (note.id)}
				<li class="bg-card rounded-[10px] border p-3" data-testid="dms-note">
					<p class="text-sm break-words whitespace-pre-wrap">{note.body}</p>
					<p class="text-muted-foreground mt-1 text-xs">
						{formatDateTime(note.noted_at ?? note.created_at, i18n.locale)}{note.origin?.startsWith('paperless:') ? ` · ${tx('dms.notes.fromPaperless')}` : ''}
					</p>
				</li>
			{/each}
		</ul>
	</section>
{/if}
