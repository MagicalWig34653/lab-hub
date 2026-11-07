<script lang="ts">
	import { goto } from '$app/navigation';
	import AuthCard from '#lib/components/app/AuthCard.svelte';
	import { Button } from '#lib/components/ui/button';
	import { Input } from '#lib/components/ui/input';
	import { Label } from '#lib/components/ui/label';
	import { errorMessage, t } from '#lib/i18n/index.svelte';
	import { session } from '#lib/session.svelte';
	import { HANDLE_PATTERN } from '#lib/validation';

	let setupToken = $state('');
	let handle = $state('');
	let displayName = $state('');
	let tenantName = $state('');
	let pending = $state(false);
	let error = $state<string | null>(null);

	async function submit(event: SubmitEvent) {
		event.preventDefault();
		pending = true;
		error = null;
		try {
			await session.bootstrap({
				setup_token: setupToken,
				handle,
				display_name: displayName,
				tenant_name: tenantName.trim() || undefined
			});
			await goto('/dashboard');
		} catch (e) {
			error = errorMessage(e);
		} finally {
			pending = false;
		}
	}
</script>

<AuthCard title={t('setup.title')} description={t('setup.description')} {error}>
	<form class="space-y-4" onsubmit={submit}>
		<div class="space-y-2">
			<Label for="setup-token">{t('setup.token')}</Label>
			<Input id="setup-token" type="password" autocomplete="off" required bind:value={setupToken} />
		</div>
		<div class="space-y-2">
			<Label for="setup-handle">{t('setup.handle')}</Label>
			<Input
				id="setup-handle"
				autocomplete="username"
				required
				pattern={HANDLE_PATTERN}
				aria-describedby="setup-handle-hint"
				bind:value={handle}
			/>
			<p id="setup-handle-hint" class="text-muted-foreground text-xs">{t('setup.handleHint')}</p>
		</div>
		<div class="space-y-2">
			<Label for="setup-display-name">{t('setup.displayName')}</Label>
			<Input id="setup-display-name" autocomplete="name" required maxlength={80} bind:value={displayName} />
		</div>
		<div class="space-y-2">
			<Label for="setup-tenant-name">{t('setup.tenantName')}</Label>
			<Input id="setup-tenant-name" maxlength={80} bind:value={tenantName} />
		</div>
		<Button type="submit" class="w-full" disabled={pending}>{t('setup.submit')}</Button>
	</form>
</AuthCard>
