<script lang="ts">
	import { goto } from '$app/navigation';
	import AuthCard from '#lib/components/app/AuthCard.svelte';
	import { Button } from '#lib/components/ui/button';
	import { Input } from '#lib/components/ui/input';
	import { Label } from '#lib/components/ui/label';
	import { errorMessage, t } from '#lib/i18n/index.svelte';
	import { session } from '#lib/session.svelte';

	let handle = $state('');
	let code = $state('');
	let pending = $state(false);
	let error = $state<string | null>(null);

	async function submit(event: SubmitEvent) {
		event.preventDefault();
		pending = true;
		error = null;
		try {
			await session.recover(handle, code.trim());
			await goto('/dashboard');
		} catch (e) {
			error = errorMessage(e);
		} finally {
			pending = false;
		}
	}
</script>

<AuthCard title={t('recover.title')} description={t('recover.description')} {error}>
	<form class="space-y-4" onsubmit={submit}>
		<div class="space-y-2">
			<Label for="recover-handle">{t('recover.handle')}</Label>
			<Input id="recover-handle" autocomplete="username" required bind:value={handle} />
		</div>
		<div class="space-y-2">
			<Label for="recover-code">{t('recover.code')}</Label>
			<Input id="recover-code" autocomplete="off" required bind:value={code} />
		</div>
		<Button type="submit" class="w-full" disabled={pending}>{t('recover.submit')}</Button>
	</form>
	<p class="text-center text-sm">
		<a class="text-muted-foreground underline underline-offset-4" href="/login">{t('recover.backToLogin')}</a>
	</p>
</AuthCard>
