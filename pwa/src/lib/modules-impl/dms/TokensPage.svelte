<script lang="ts">
	import { onDestroy } from 'svelte';
	import { apiTokenApi, type ApiToken } from '#lib/api/client';
	import ConfirmDialog from '#lib/components/app/ConfirmDialog.svelte';
	import ErrorBanner from '#lib/components/app/ErrorBanner.svelte';
	import { Button } from '#lib/components/ui/button';
	import { Input } from '#lib/components/ui/input';
	import { formatDateTime } from '#lib/format';
	import { errorMessage, i18n, tx } from '#lib/i18n/index.svelte';
	import { TOKEN_SCOPE } from './permissions';

	/** Personal API tokens for the share/scan API (scope `dms.upload`). The plain token is shown exactly once, after creating. */
	let tokens = $state<ApiToken[]>([]);
	let loading = $state(true);
	let error = $state<string | null>(null);
	let name = $state('');
	let days = $state('365');
	let busy = $state(false);
	let submitted = $state(false);
	/** The one-time plain token. Cleared on dismiss and when the page is left; never stored anywhere else. */
	let fresh = $state<{ id: string; name: string; token: string } | null>(null);
	let copied = $state<'ok' | 'failed' | null>(null);
	let revoking = $state<ApiToken | null>(null);
	let revokeBusy = $state(false);
	let revokeError = $state<string | null>(null);

	// A number input bound with bind:value yields a number (null when empty), so normalise first.
	const daysValid = $derived(/^\d+$/.test(String(days ?? '').trim()) && Number(days) >= 1 && Number(days) <= 730);
	const nameValid = $derived(name.trim().length > 0);

	async function load() {
		try {
			tokens = (await apiTokenApi.list()).items;
			error = null;
		} catch (e) {
			error = errorMessage(e);
		} finally {
			loading = false;
		}
	}
	void load();
	onDestroy(() => (fresh = null));

	const stateOf = (token: ApiToken): 'revoked' | 'expired' | 'active' =>
		token.revoked_at ? 'revoked' : new Date(token.expires_at).getTime() <= Date.now() ? 'expired' : 'active';

	async function create(event: SubmitEvent) {
		event.preventDefault();
		submitted = true;
		if (!nameValid || !daysValid) return;
		busy = true;
		error = null;
		try {
			const created = await apiTokenApi.create({ name: name.trim(), scopes: [TOKEN_SCOPE], expires_in_days: Number(days) });
			fresh = created.token ? { id: created.id, name: created.name, token: created.token } : null;
			copied = null;
			name = '';
			submitted = false;
			await load();
		} catch (e) {
			error = errorMessage(e);
		} finally {
			busy = false;
		}
	}

	async function copy() {
		if (!fresh) return;
		try {
			await navigator.clipboard.writeText(fresh.token);
			copied = 'ok';
		} catch {
			copied = 'failed';
		}
	}

	async function confirmRevoke() {
		if (!revoking) return;
		revokeBusy = true;
		revokeError = null;
		try {
			await apiTokenApi.revoke(revoking.id);
			if (fresh?.id === revoking.id) fresh = null;
			revoking = null;
			await load();
		} catch (e) {
			revokeError = errorMessage(e);
		} finally {
			revokeBusy = false;
		}
	}
</script>

<h1 class="mb-1 text-2xl font-semibold" data-testid="tokens-title">{tx('dms.tokens.title')}</h1>
<p class="text-muted-foreground mb-1 text-sm">{tx('dms.tokens.intro')}</p>
<p class="mb-4 text-sm"><a class="text-primary underline" href="/dms/scanner" data-testid="tokens-to-scanner">{tx('dms.tokens.toScanner')}</a></p>
<ErrorBanner message={error} />

{#if fresh}
	<section class="border-primary mb-5 rounded-lg border-2 p-4" aria-labelledby="token-fresh-title" data-testid="token-fresh">
		<h2 id="token-fresh-title" class="mb-1 text-base font-semibold">{tx('dms.tokens.freshTitle', { name: fresh.name })}</h2>
		<p class="mb-2 text-sm font-medium" role="alert">{tx('dms.tokens.freshWarning')}</p>
		<p class="bg-muted rounded-md p-2 font-mono text-sm break-all select-all" data-testid="token-plain">{fresh.token}</p>
		<div class="mt-3 flex flex-wrap items-center gap-2">
			<Button type="button" onclick={copy} data-testid="token-copy">{tx('dms.tokens.copy')}</Button>
			<Button type="button" variant="outline" onclick={() => ((fresh = null), (copied = null))} data-testid="token-dismiss">{tx('dms.tokens.dismiss')}</Button>
			{#if copied === 'ok'}<span role="status" class="text-sm" data-testid="token-copied">{tx('dms.tokens.copied')}</span>{/if}
			{#if copied === 'failed'}<span role="alert" class="text-destructive text-sm">{tx('dms.tokens.copyFailed')}</span>{/if}
		</div>
	</section>
{/if}

<form onsubmit={create} class="mb-5 flex flex-wrap items-end gap-3 rounded-lg border p-3" novalidate data-testid="token-form">
	<label class="text-sm">
		<span class="mb-1 block">{tx('dms.tokens.name')}</span>
		<Input class="w-64" bind:value={name} maxlength={80} aria-invalid={submitted && !nameValid} data-testid="token-name" />
	</label>
	<label class="text-sm">
		<span class="mb-1 block">{tx('dms.tokens.scope')}</span>
		<select class="border-input bg-background h-8 rounded-lg border px-2 text-sm" data-testid="token-scope">
			<option value={TOKEN_SCOPE}>{tx('dms.tokens.scope.upload')}</option>
		</select>
	</label>
	<label class="text-sm">
		<span class="mb-1 block">{tx('dms.tokens.expiresInDays')}</span>
		<Input class="w-28" type="number" min="1" max="730" bind:value={days} aria-invalid={submitted && !daysValid} data-testid="token-days" />
	</label>
	<Button type="submit" disabled={busy} data-testid="token-create">{tx('dms.tokens.create')}</Button>
</form>
{#if submitted && (!nameValid || !daysValid)}
	<p role="alert" class="text-destructive mb-3 text-sm" data-testid="token-problem">{tx(nameValid ? 'dms.tokens.daysInvalid' : 'dms.tokens.nameRequired')}</p>
{/if}
<p class="text-muted-foreground mb-4 text-xs">{tx('dms.tokens.hint')}</p>

{#if loading}
	<p class="text-muted-foreground text-sm">{tx('common.loading')}</p>
{:else if tokens.length === 0}
	<p class="text-muted-foreground" data-testid="tokens-empty">{tx('dms.tokens.empty')}</p>
{:else}
	<div class="overflow-x-auto">
		<table class="w-full text-left text-sm" data-testid="tokens-table">
			<caption class="sr-only">{tx('dms.tokens.title')}</caption>
			<thead>
				<tr class="text-muted-foreground border-b">
					<th scope="col" class="py-2 pr-3">{tx('dms.tokens.name')}</th>
					<th scope="col" class="py-2 pr-3">{tx('dms.tokens.scope')}</th>
					<th scope="col" class="py-2 pr-3">{tx('dms.tokens.created')}</th>
					<th scope="col" class="py-2 pr-3">{tx('dms.tokens.expires')}</th>
					<th scope="col" class="py-2 pr-3">{tx('dms.tokens.lastUsed')}</th>
					<th scope="col" class="py-2 pr-3">{tx('dms.tokens.state')}</th>
					<th scope="col" class="py-2"><span class="sr-only">{tx('dms.actions.title')}</span></th>
				</tr>
			</thead>
			<tbody>
				{#each tokens as token (token.id)}
					{@const state = stateOf(token)}
					<tr class="border-b align-top" data-testid="token-row" data-state={state}>
						<td class="py-2 pr-3 font-medium">{token.name}</td>
						<td class="py-2 pr-3 font-mono text-xs">{token.scopes.join(', ')}</td>
						<td class="py-2 pr-3">{formatDateTime(token.created_at, i18n.locale)}</td>
						<td class="py-2 pr-3">{formatDateTime(token.expires_at, i18n.locale)}</td>
						<td class="py-2 pr-3">{token.last_used_at ? formatDateTime(token.last_used_at, i18n.locale) : tx('dms.tokens.neverUsed')}</td>
						<td class="py-2 pr-3" data-testid="token-state">
							{tx(state === 'active' ? 'dms.tokens.state.active' : state === 'revoked' ? 'dms.tokens.state.revoked' : 'dms.tokens.state.expired')}
						</td>
						<td class="py-2">
							{#if state === 'active'}
								<Button
									type="button"
									size="sm"
									variant="outline"
									aria-label={tx('dms.tokens.revokeNamed', { name: token.name })}
									onclick={() => ((revoking = token), (revokeError = null))}
									data-testid="token-revoke"
								>
									{tx('dms.tokens.revoke')}
								</Button>
							{/if}
						</td>
					</tr>
				{/each}
			</tbody>
		</table>
	</div>
{/if}

<ConfirmDialog
	open={revoking !== null}
	title={tx('dms.tokens.revoke')}
	confirmLabel={tx('dms.tokens.revoke')}
	destructive
	busy={revokeBusy}
	error={revokeError}
	testid="token-revoke-dialog"
	onconfirm={confirmRevoke}
	oncancel={() => (revoking = null)}
>
	<p>{tx('dms.tokens.revokeText', { name: revoking?.name ?? '' })}</p>
</ConfirmDialog>
