<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import AuthCard from '#lib/components/app/AuthCard.svelte';
	import { Button } from '#lib/components/ui/button';
	import { Input } from '#lib/components/ui/input';
	import { Label } from '#lib/components/ui/label';
	import { errorMessage, t } from '#lib/i18n/index.svelte';
	import { session } from '#lib/session.svelte';
	import { HANDLE_PATTERN } from '#lib/validation';

	let handle = $state('');
	let displayName = $state('');
	let pending = $state(false);
	let error = $state<string | null>(null);

	async function submit(event: SubmitEvent) {
		event.preventDefault();
		pending = true;
		error = null;
		try {
			await session.acceptInvitation({
				invite_token: page.params.token ?? '',
				handle,
				display_name: displayName
			});
			await goto('/dashboard');
		} catch (e) {
			error = errorMessage(e);
		} finally {
			pending = false;
		}
	}
</script>

<AuthCard title={t('invite.title')} description={t('invite.description')} {error}>
	<form class="space-y-4" onsubmit={submit}>
		<div class="space-y-2">
			<Label for="invite-handle">{t('invite.handle')}</Label>
			<Input
				id="invite-handle"
				autocomplete="username"
				required
				pattern={HANDLE_PATTERN}
				aria-describedby="invite-handle-hint"
				bind:value={handle}
			/>
			<p id="invite-handle-hint" class="text-muted-foreground text-xs">{t('invite.handleHint')}</p>
		</div>
		<div class="space-y-2">
			<Label for="invite-display-name">{t('invite.displayName')}</Label>
			<Input id="invite-display-name" autocomplete="name" required maxlength={80} bind:value={displayName} />
		</div>
		<Button type="submit" class="w-full" disabled={pending}>{t('invite.submit')}</Button>
	</form>
</AuthCard>
