<script lang="ts">
	import { ApiError, dmsAdminApi, dmsApi, type DmsDeletionLogEntry, type DmsDocument, type DmsRetention } from '#lib/api/client';
	import ConfirmDialog from '#lib/components/app/ConfirmDialog.svelte';
	import ErrorBanner from '#lib/components/app/ErrorBanner.svelte';
	import { Button } from '#lib/components/ui/button';
	import { Input } from '#lib/components/ui/input';
	import { formatBytes, formatDate, formatDateTime } from '#lib/format';
	import { errorMessage, i18n, tx } from '#lib/i18n/index.svelte';
	import { workspace } from '#lib/workspace.svelte';
	import { P } from './permissions';

	let { tenant }: { tenant: string } = $props();
	// svelte-ignore state_referenced_locally
	const tenantId = tenant;

	const canPurge = $derived(workspace.can(P.documentPurge));
	const canRetention = $derived(workspace.can(P.documentRetention));

	const blockerText = {
		document_not_trashed: 'dms.trash.blocker.document_not_trashed',
		legal_hold: 'dms.trash.blocker.legal_hold',
		retention_not_expired: 'dms.trash.blocker.retention_not_expired',
		document_linked: 'dms.trash.blocker.document_linked'
	} as const;
	const sourceText = {
		document_type: 'dms.trash.source.document_type',
		default: 'dms.trash.source.default',
		manual: 'dms.trash.source.manual',
		none: 'dms.trash.source.none'
	} as const;

	let docs = $state<DmsDocument[]>([]);
	let nextCursor = $state<string | null>(null);
	let retention = $state<Record<string, DmsRetention>>({});
	let log = $state<DmsDeletionLogEntry[]>([]);
	let loading = $state(true);
	let error = $state<string | null>(null);
	let notice = $state<string | null>(null);
	let busyId = $state<string | null>(null);
	let extendDate = $state<Record<string, string>>({});
	let seq = 0;

	let purging = $state<DmsDocument | null>(null);
	let purgeAck = $state(false);
	let purgeBusy = $state(false);
	let purgeError = $state<string | null>(null);

	async function loadRetention(items: DmsDocument[]) {
		let index = 0;
		const worker = async () => {
			while (index < items.length) {
				const doc = items[index++];
				try {
					retention[doc.id] = await dmsAdminApi.retention(tenantId, doc.id);
				} catch {
					// the row still works without the retention state (purge stays disabled)
				}
			}
		};
		await Promise.all([worker(), worker(), worker()]);
	}

	async function load(reset: boolean) {
		const mine = ++seq;
		loading = true;
		error = null;
		try {
			const page = await dmsApi.documents(tenantId, { trashed: true, cursor: reset ? null : nextCursor, limit: 25 });
			if (mine !== seq) return;
			docs = reset ? page.items : [...docs, ...page.items];
			nextCursor = page.next_cursor ?? null;
			void loadRetention(page.items);
		} catch (e) {
			if (mine === seq) error = errorMessage(e);
		} finally {
			if (mine === seq) loading = false;
		}
	}

	async function loadLog() {
		try {
			log = (await dmsAdminApi.deletionLog(tenantId)).items;
		} catch (e) {
			error = errorMessage(e);
		}
	}

	void load(true);
	void loadLog();

	async function restore(doc: DmsDocument) {
		busyId = doc.id;
		error = null;
		notice = null;
		try {
			await dmsApi.restore(tenantId, doc.id);
			docs = docs.filter((d) => d.id !== doc.id);
			notice = tx('dms.trash.restored', { title: doc.title });
		} catch (e) {
			error = errorMessage(e);
		} finally {
			busyId = null;
		}
	}

	async function setRetention(doc: DmsDocument, body: { legal_hold?: boolean; retention_until?: string }) {
		busyId = doc.id;
		error = null;
		try {
			retention[doc.id] = await dmsAdminApi.setRetention(tenantId, doc.id, body);
		} catch (e) {
			error = errorMessage(e);
		} finally {
			busyId = null;
		}
	}

	function openPurge(doc: DmsDocument) {
		purging = doc;
		purgeAck = false;
		purgeError = null;
	}

	async function confirmPurge() {
		const doc = purging;
		if (!doc || !purgeAck) return;
		purgeBusy = true;
		purgeError = null;
		try {
			await dmsAdminApi.purge(tenantId, doc.id);
			docs = docs.filter((d) => d.id !== doc.id);
			purging = null;
			notice = tx('dms.trash.purged', { title: doc.title });
			await loadLog();
		} catch (e) {
			// 409 with the first blocking reason (retention_not_expired, legal_hold, document_linked, document_not_trashed)
			purgeError = errorMessage(e);
			if (e instanceof ApiError && e.status === 409) {
				try {
					retention[doc.id] = await dmsAdminApi.retention(tenantId, doc.id);
				} catch {
					// keep the old state
				}
			}
		} finally {
			purgeBusy = false;
		}
	}

	const shortHash = (h: string) => `${h.slice(0, 12)}…`;
</script>

<h1 class="mb-1 text-2xl font-semibold" data-testid="trash-title">{tx('dms.trash.title')}</h1>
<p class="text-muted-foreground mb-1 text-sm">{tx('dms.trash.intro')}</p>
<p class="text-muted-foreground mb-4 text-xs" data-testid="trash-gobd">{tx('dms.trash.gobdNote')}</p>

<ErrorBanner message={error} />
{#if notice}<p role="status" class="mb-3 text-sm" data-testid="trash-notice">{notice}</p>{/if}

{#if loading && docs.length === 0}
	<p class="text-muted-foreground text-sm">{tx('common.loading')}</p>
{:else if docs.length === 0 && !error}
	<p class="text-muted-foreground" data-testid="trash-empty">{tx('dms.list.trashEmpty')}</p>
{:else}
	<ul class="space-y-3" data-testid="trash-list">
		{#each docs as doc (doc.id)}
			{@const r = retention[doc.id]}
			<li class="rounded-lg border p-3" data-testid="trash-row" data-can-purge={r?.can_purge ?? false}>
				<div class="flex flex-wrap items-start justify-between gap-3">
					<div class="min-w-0">
						<a class="font-medium break-words underline-offset-2 hover:underline" href={`/dms/${doc.id}`} data-testid="trash-doc-title">{doc.title}</a>
						<p class="text-muted-foreground text-xs">
							{tx('dms.trash.trashedAt', { date: doc.trashed_at ? formatDateTime(doc.trashed_at, i18n.locale) : '' })}
							· {tx('dms.trash.reasonLabel')}: {doc.trash_reason ?? ''}
						</p>
					</div>
					<div class="flex flex-wrap gap-2">
						<Button type="button" size="sm" variant="outline" disabled={busyId === doc.id} onclick={() => restore(doc)} data-testid="trash-restore">{tx('dms.trash.restore')}</Button>
						{#if canPurge}
							<Button type="button" size="sm" variant="outline" class="text-destructive" disabled={busyId === doc.id || !r?.can_purge} onclick={() => openPurge(doc)} data-testid="trash-purge">
								{tx('dms.trash.purge')}
							</Button>
						{/if}
					</div>
				</div>
				{#if r}
					<dl class="mt-2 grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm" data-testid="trash-retention">
						<dt class="text-muted-foreground">{tx('dms.trash.retentionUntil')}</dt>
						<dd data-testid="trash-retention-until">
							{r.retention_until ? formatDate(r.retention_until, i18n.locale) : tx('dms.trash.noRetention')}
							<span class="text-muted-foreground text-xs">({tx(sourceText[r.retention_source])})</span>
						</dd>
						<dt class="text-muted-foreground">{tx('dms.trash.legalHold')}</dt>
						<dd data-testid="trash-legal-hold">{tx(r.legal_hold ? 'dms.masters.yes' : 'dms.masters.no')}</dd>
						<dt class="text-muted-foreground">{tx('dms.trash.purgeState')}</dt>
						<dd data-testid="trash-purge-state">
							{#if r.can_purge}
								{tx('dms.trash.canPurge')}
							{:else}
								<ul class="list-disc pl-4">
									{#each r.blockers as b (b)}<li>{tx(blockerText[b])}</li>{/each}
								</ul>
							{/if}
						</dd>
					</dl>
					{#if canRetention}
						<div class="mt-2 flex flex-wrap items-end gap-3">
							<Button type="button" size="sm" variant="outline" disabled={busyId === doc.id} onclick={() => setRetention(doc, { legal_hold: !r.legal_hold })} data-testid="trash-hold-toggle">
								{tx(r.legal_hold ? 'dms.trash.holdRelease' : 'dms.trash.holdSet')}
							</Button>
							<label class="text-sm">
								<span class="mb-1 block">{tx('dms.trash.extendTo')}</span>
								<Input type="date" class="w-44" bind:value={extendDate[doc.id]} data-testid="trash-extend-date" />
							</label>
							<Button type="button" size="sm" variant="outline" disabled={busyId === doc.id || !extendDate[doc.id]} onclick={() => setRetention(doc, { retention_until: extendDate[doc.id] })} data-testid="trash-extend">
								{tx('dms.trash.extend')}
							</Button>
						</div>
					{/if}
				{/if}
			</li>
		{/each}
	</ul>
	{#if nextCursor}
		<Button type="button" variant="outline" class="mt-3" disabled={loading} onclick={() => load(false)}>{tx('dms.list.more')}</Button>
	{/if}
{/if}
{#if !canPurge}<p class="text-muted-foreground mt-3 text-xs" data-testid="trash-owner-only">{tx('dms.trash.ownerOnly')}</p>{/if}

<h2 class="mt-8 mb-2 text-lg font-medium">{tx('dms.trash.logTitle')}</h2>
<p class="text-muted-foreground mb-2 text-xs">{tx('dms.trash.logIntro')}</p>
{#if log.length === 0}
	<p class="text-muted-foreground text-sm" data-testid="deletion-log-empty">{tx('dms.trash.logEmpty')}</p>
{:else}
	<div class="overflow-x-auto">
		<table class="w-full text-left text-sm" data-testid="deletion-log">
			<caption class="sr-only">{tx('dms.trash.logTitle')}</caption>
			<thead>
				<tr class="text-muted-foreground border-b">
					<th scope="col" class="py-1 pr-3">{tx('dms.trash.log.purgedAt')}</th>
					<th scope="col" class="py-1 pr-3">{tx('dms.field.asn')}</th>
					<th scope="col" class="py-1 pr-3">{tx('dms.field.date')}</th>
					<th scope="col" class="py-1 pr-3">{tx('dms.trash.retentionUntil')}</th>
					<th scope="col" class="py-1 pr-3">{tx('dms.field.sha')}</th>
					<th scope="col" class="py-1 pr-3">{tx('dms.trash.log.size')}</th>
					<th scope="col" class="py-1">{tx('dms.trash.log.files')}</th>
				</tr>
			</thead>
			<tbody>
				{#each log as e (e.id)}
					<tr class="border-b" data-testid="deletion-log-row">
						<td class="py-1 pr-3">{formatDateTime(e.purged_at, i18n.locale)}</td>
						<td class="py-1 pr-3">{e.asn ?? '–'}</td>
						<td class="py-1 pr-3">{formatDate(e.doc_date, i18n.locale) || '–'}</td>
						<td class="py-1 pr-3">{formatDate(e.retention_until, i18n.locale) || '–'}</td>
						<td class="py-1 pr-3 font-mono text-xs" title={e.original_sha256}>{shortHash(e.original_sha256)}</td>
						<td class="py-1 pr-3">{formatBytes(e.original_size, i18n.locale)}</td>
						<td class="py-1">{e.file_count}</td>
					</tr>
				{/each}
			</tbody>
		</table>
	</div>
{/if}

<ConfirmDialog
	open={purging !== null}
	title={tx('dms.trash.purgeTitle')}
	confirmLabel={tx('dms.trash.purgeConfirm')}
	destructive
	busy={purgeBusy || !purgeAck}
	error={purgeError}
	testid="purge-dialog"
	onconfirm={confirmPurge}
	oncancel={() => (purging = null)}
>
	<p data-testid="purge-dialog-text">{tx('dms.trash.purgeText', { title: purging?.title ?? '' })}</p>
	<p class="text-muted-foreground text-xs">{tx('dms.trash.purgeLog')}</p>
	<label class="flex items-start gap-2">
		<input type="checkbox" bind:checked={purgeAck} class="mt-0.5" data-testid="purge-ack" />
		<span>{tx('dms.trash.purgeAck')}</span>
	</label>
</ConfirmDialog>
