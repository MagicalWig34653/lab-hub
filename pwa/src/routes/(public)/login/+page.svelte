<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import AuthCard from '#lib/components/app/AuthCard.svelte';
	import { Button } from '#lib/components/ui/button';
	import { errorMessage, t } from '#lib/i18n/index.svelte';
	import { safeNext } from '#lib/navigation';
	import { session } from '#lib/session.svelte';

	let pending = $state(false);
	let error = $state<string | null>(null);

	async function signIn() {
		pending = true;
		error = null;
		try {
			await session.login();
			await goto(safeNext(page.url.searchParams.get('next')));
		} catch (e) {
			error = errorMessage(e);
		} finally {
			pending = false;
		}
	}
</script>

<AuthCard title={t('login.title')} description={t('login.description')} {error}>
	<Button class="w-full" disabled={pending} onclick={signIn} data-testid="login-passkey">
		{pending ? t('login.pending') : t('login.passkey')}
	</Button>
	<p class="text-center text-sm">
		<a class="text-muted-foreground underline underline-offset-4" href="/recover">{t('login.recoverLink')}</a>
	</p>
</AuthCard>
