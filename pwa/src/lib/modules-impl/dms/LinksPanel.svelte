<script lang="ts">
	import { dmsApi, linkApi } from '#lib/api/client';
	import { tx } from '#lib/i18n/index.svelte';
	import { LINK_DOC_TYPE } from './permissions';
	import { workspace } from '#lib/workspace.svelte';

	/**
	 * Links of a document (core links, `contact.link.read`): mail and attachment (`mail_attachment`, from = attachment).
	 * Titles of linked documents come from the document route; a document that cannot be read is shown without a title.
	 */
	let { tenant, documentId }: { tenant: string; documentId: string } = $props();
	// svelte-ignore state_referenced_locally
	const tenantId = tenant;
	// svelte-ignore state_referenced_locally
	const docId = documentId;

	interface Entry {
		linkId: string;
		otherId: string;
		role: 'mail' | 'attachment';
		title: string;
	}
	let entries = $state<Entry[]>([]);
	let loaded = $state(false);

	async function load() {
		if (!workspace.can('contact.link.read')) return;
		try {
			const { items } = await linkApi.list(tenantId, LINK_DOC_TYPE, docId);
			const found: Entry[] = [];
			for (const link of items.filter((l) => l.kind === 'mail_attachment' && l.from_type === LINK_DOC_TYPE && l.to_type === LINK_DOC_TYPE && !l.removed_at).slice(0, 20)) {
				// from = attachment, to = mail: this document is the attachment when it is the `from` end.
				const asAttachment = link.from_id.toLowerCase() === docId.toLowerCase();
				const otherId = asAttachment ? link.to_id : link.from_id;
				let title = '';
				try {
					title = (await dmsApi.document(tenantId, otherId)).title;
				} catch {
					// no right or gone: keep the link without a title
				}
				found.push({ linkId: link.id, otherId, role: asAttachment ? 'mail' : 'attachment', title });
			}
			entries = found;
		} catch {
			// links are a convenience; the page works without them
		} finally {
			loaded = true;
		}
	}
	void load();
</script>

{#if loaded && entries.length > 0}
	<section class="mt-8" aria-labelledby="dms-links-title" data-testid="dms-links">
		<h2 id="dms-links-title" class="mb-2 text-lg font-medium">{tx('dms.links.title')}</h2>
		<ul class="divide-y rounded-md border text-sm">
			{#each entries as entry (entry.linkId)}
				<li class="flex flex-wrap items-center gap-x-3 p-3" data-testid="dms-link" data-role={entry.role}>
					<span class="text-muted-foreground">{tx(entry.role === 'mail' ? 'dms.links.mail' : 'dms.links.attachment')}</span>
					<a href={`/dms/${entry.otherId}`} class="font-medium break-words underline-offset-2 hover:underline">{entry.title || entry.otherId.slice(0, 8)}</a>
				</li>
			{/each}
		</ul>
	</section>
{/if}
