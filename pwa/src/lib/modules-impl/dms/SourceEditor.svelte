<script lang="ts">
	import { ApiError, dmsSourcesApi, type DmsSource } from '#lib/api/client';
	import ErrorBanner from '#lib/components/app/ErrorBanner.svelte';
	import { Button } from '#lib/components/ui/button';
	import { Input } from '#lib/components/ui/input';
	import { errorMessage, tx } from '#lib/i18n/index.svelte';
	import {
		createInput,
		emptyFolder,
		emptyMail,
		fieldErrorKey,
		folderConfig,
		folderFromSource,
		mailConfig,
		mailFromSource,
		validateFolder,
		validateMail,
		type FolderDraft,
		type MailDraft,
		type SourceKind
	} from './sources';

	/** Create (`source` null) or edit a source. The password is write only: it is never shown, an empty field keeps the stored one. */
	let {
		tenant,
		kind,
		source,
		onsaved,
		oncancel
	}: { tenant: string; kind: SourceKind; source: DmsSource | null; onsaved: (saved: DmsSource) => void; oncancel: () => void } = $props();
	// svelte-ignore state_referenced_locally
	const tenantId = tenant;
	// svelte-ignore state_referenced_locally
	const editing = source !== null;

	// svelte-ignore state_referenced_locally
	let name = $state(source?.name ?? '');
	// svelte-ignore state_referenced_locally
	let mail = $state<MailDraft>(source && kind === 'mail' ? mailFromSource(source) : emptyMail());
	// svelte-ignore state_referenced_locally
	let folder = $state<FolderDraft>(source && kind === 'folder' ? folderFromSource(source) : emptyFolder());
	let busy = $state(false);
	let error = $state<string | null>(null);
	let fieldErrors = $state<{ field: string; code: string }[]>([]);
	let submitted = $state(false);

	const problems = $derived(kind === 'mail' ? validateMail(mail, name, editing) : validateFolder(folder, name));
	const has = (key: string) => submitted && problems.includes(key);
	const hasField = (field: string) => fieldErrors.some((f) => f.field === field);

	const problemText: Record<string, string> = {
		nameRequired: 'dms.sources.problem.nameRequired',
		hostRequired: 'dms.sources.problem.hostRequired',
		hostInvalid: 'dms.sources.problem.hostInvalid',
		portInvalid: 'dms.sources.problem.portInvalid',
		usernameRequired: 'dms.sources.problem.usernameRequired',
		passwordRequired: 'dms.sources.problem.passwordRequired',
		mailIntervalInvalid: 'dms.sources.problem.mailIntervalInvalid',
		maxInvalid: 'dms.sources.problem.maxInvalid',
		asciiOnly: 'dms.sources.problem.asciiOnly',
		pathRequired: 'dms.sources.problem.pathRequired',
		pathInvalid: 'dms.sources.problem.pathInvalid',
		folderIntervalInvalid: 'dms.sources.problem.folderIntervalInvalid',
		stableInvalid: 'dms.sources.problem.stableInvalid'
	};

	async function save(event: SubmitEvent) {
		event.preventDefault();
		submitted = true;
		error = null;
		fieldErrors = [];
		if (problems.length > 0) return;
		busy = true;
		try {
			let saved: DmsSource;
			if (source) {
				const body: Parameters<typeof dmsSourcesApi.update>[2] = { name: name.trim(), config: kind === 'mail' ? mailConfig(mail) : folderConfig(folder) };
				if (kind === 'mail' && mail.password) body.password = mail.password;
				saved = await dmsSourcesApi.update(tenantId, source.id, body);
			} else {
				saved = await dmsSourcesApi.create(tenantId, createInput(kind, name, kind === 'mail' ? mail : folder));
			}
			mail.password = '';
			onsaved(saved);
		} catch (e) {
			if (e instanceof ApiError && e.code === 'validation_failed' && e.fieldErrors.length > 0) fieldErrors = e.fieldErrors;
			else if (e instanceof ApiError && e.code === 'conflict' && e.status === 409) error = tx('dms.sources.nameTaken');
			else error = errorMessage(e);
		} finally {
			busy = false;
		}
	}
</script>

<h1 class="mb-1 text-2xl font-semibold" data-testid="source-editor-title">
	{tx(editing ? (kind === 'mail' ? 'dms.sources.editMail' : 'dms.sources.editFolder') : kind === 'mail' ? 'dms.sources.newMail' : 'dms.sources.newFolder')}
</h1>
<p class="text-muted-foreground mb-4 text-sm">{tx(kind === 'mail' ? 'dms.sources.mailIntro' : 'dms.sources.folderIntro')}</p>
<ErrorBanner message={error} />
{#if fieldErrors.length > 0}
	<div role="alert" data-testid="source-field-errors">
		<ul class="text-destructive mb-3 list-disc pl-5 text-sm">
			{#each fieldErrors as fe (fe.field + fe.code)}
				<li data-field={fe.field}>{tx(fieldErrorKey(fe.field, fe.code), { field: fe.field })}</li>
			{/each}
		</ul>
	</div>
{/if}
{#if submitted && problems.length > 0}
	<div role="alert" data-testid="source-problems">
		<ul class="text-destructive mb-3 list-disc pl-5 text-sm">
			{#each problems as p (p)}<li>{tx(problemText[p])}</li>{/each}
		</ul>
	</div>
{/if}

<form onsubmit={save} class="space-y-5" novalidate data-testid="source-form">
	<fieldset class="grid gap-3 sm:grid-cols-2">
		<legend class="mb-2 text-base font-medium">{tx('dms.sources.section.general')}</legend>
		<label class="block text-sm sm:col-span-2">
			<span class="mb-1 block">{tx('dms.sources.name')}</span>
			<Input bind:value={name} maxlength={100} aria-invalid={has('nameRequired')} data-testid="source-name" />
		</label>
	</fieldset>

	{#if kind === 'mail'}
		<fieldset class="grid gap-3 sm:grid-cols-2">
			<legend class="mb-2 text-base font-medium">{tx('dms.sources.section.connection')}</legend>
			<label class="block text-sm">
				<span class="mb-1 block">{tx('dms.sources.host')}</span>
				<Input bind:value={mail.host} maxlength={253} autocomplete="off" aria-invalid={has('hostRequired') || has('hostInvalid') || hasField('config.host')} data-testid="source-host" />
				<span class="text-muted-foreground mt-1 block text-xs">{tx('dms.sources.hostHint')}</span>
			</label>
			<label class="block text-sm">
				<span class="mb-1 block">{tx('dms.sources.port')}</span>
				<Input type="number" min="1" max="65535" bind:value={mail.port} aria-invalid={has('portInvalid')} data-testid="source-port" />
				<span class="text-muted-foreground mt-1 block text-xs">{tx('dms.sources.portHint')}</span>
			</label>
			<label class="block text-sm">
				<span class="mb-1 block">{tx('dms.sources.username')}</span>
				<Input bind:value={mail.username} maxlength={256} autocomplete="off" aria-invalid={has('usernameRequired')} data-testid="source-username" />
			</label>
			<label class="block text-sm">
				<span class="mb-1 block">{tx('dms.sources.password')}</span>
				<Input
					type="password"
					bind:value={mail.password}
					maxlength={512}
					autocomplete="new-password"
					placeholder={editing && source?.has_secret ? tx('dms.sources.passwordStored') : ''}
					aria-invalid={has('passwordRequired') || hasField('password')}
					data-testid="source-password"
				/>
				<span class="text-muted-foreground mt-1 block text-xs">{tx(editing ? 'dms.sources.passwordHintEdit' : 'dms.sources.passwordHint')}</span>
			</label>
		</fieldset>

		<fieldset class="grid gap-3 sm:grid-cols-2">
			<legend class="mb-2 text-base font-medium">{tx('dms.sources.section.processing')}</legend>
			<label class="block text-sm">
				<span class="mb-1 block">{tx('dms.sources.mailbox')}</span>
				<Input bind:value={mail.mailbox} maxlength={200} aria-invalid={has('asciiOnly')} data-testid="source-mailbox" />
			</label>
			<label class="block text-sm">
				<span class="mb-1 block">{tx('dms.sources.processedMailbox')}</span>
				<Input bind:value={mail.processed_mailbox} maxlength={200} aria-invalid={has('asciiOnly')} data-testid="source-processed-mailbox" />
				<span class="text-muted-foreground mt-1 block text-xs">{tx('dms.sources.processedMailboxHint')}</span>
			</label>
			<label class="block text-sm">
				<span class="mb-1 block">{tx('dms.sources.senderContains')}</span>
				<Input bind:value={mail.sender_contains} maxlength={100} data-testid="source-sender" />
			</label>
			<label class="block text-sm">
				<span class="mb-1 block">{tx('dms.sources.subjectContains')}</span>
				<Input bind:value={mail.subject_contains} maxlength={100} data-testid="source-subject" />
			</label>
			<label class="block text-sm">
				<span class="mb-1 block">{tx('dms.sources.intervalSeconds')}</span>
				<Input type="number" min="30" max="86400" bind:value={mail.interval_seconds} aria-invalid={has('mailIntervalInvalid')} data-testid="source-interval" />
				<span class="text-muted-foreground mt-1 block text-xs">{tx('dms.sources.mailIntervalHint')}</span>
			</label>
			<label class="block text-sm">
				<span class="mb-1 block">{tx('dms.sources.maxPerRun')}</span>
				<Input type="number" min="1" max="200" bind:value={mail.max_per_run} aria-invalid={has('maxInvalid')} data-testid="source-max" />
			</label>
			<label class="flex items-center gap-2 text-sm sm:col-span-2">
				<input type="checkbox" bind:checked={mail.include_body} data-testid="source-include-body" />
				{tx('dms.sources.includeBody')}
			</label>
			<p class="text-muted-foreground text-xs sm:col-span-2">{tx('dms.sources.mailRuleNote')}</p>
		</fieldset>
	{:else}
		<fieldset class="grid gap-3 sm:grid-cols-2">
			<legend class="mb-2 text-base font-medium">{tx('dms.sources.section.folder')}</legend>
			<label class="block text-sm sm:col-span-2">
				<span class="mb-1 block">{tx('dms.sources.path')}</span>
				<Input bind:value={folder.path} maxlength={200} autocomplete="off" aria-invalid={has('pathRequired') || has('pathInvalid') || hasField('config.path')} data-testid="source-path" />
				<span class="text-muted-foreground mt-1 block text-xs">{tx('dms.sources.pathHint')}</span>
				<span class="text-muted-foreground mt-1 block font-mono text-xs break-all" data-testid="source-path-preview">{tx('dms.sources.pathPreview', { tenant: tenantId, path: folder.path.trim() || '…' })}</span>
			</label>
			<label class="block text-sm">
				<span class="mb-1 block">{tx('dms.sources.intervalSeconds')}</span>
				<Input type="number" min="10" max="86400" bind:value={folder.interval_seconds} aria-invalid={has('folderIntervalInvalid')} data-testid="source-interval" />
			</label>
			<label class="block text-sm">
				<span class="mb-1 block">{tx('dms.sources.stableSeconds')}</span>
				<Input type="number" min="0" max="3600" bind:value={folder.stable_seconds} aria-invalid={has('stableInvalid')} data-testid="source-stable" />
				<span class="text-muted-foreground mt-1 block text-xs">{tx('dms.sources.stableHint')}</span>
			</label>
		</fieldset>
	{/if}

	<div class="flex gap-2">
		<Button type="submit" disabled={busy} data-testid="source-save">{tx('dms.sources.save')}</Button>
		<Button type="button" variant="outline" onclick={oncancel} data-testid="source-cancel">{tx('common.cancel')}</Button>
	</div>
</form>
