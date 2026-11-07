<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import LanguageSwitch from '#lib/components/app/LanguageSwitch.svelte';
	import { Button } from '#lib/components/ui/button';
	import { t } from '#lib/i18n/index.svelte';
	import { session } from '#lib/session.svelte';

	let { children } = $props();

	// The session can vanish while the page is open (revoked on another device): leave quietly.
	$effect(() => {
		if (session.loaded && !session.current) {
			void goto(`/login?next=${encodeURIComponent(page.url.pathname + page.url.search)}`);
		}
	});

	async function logout() {
		await session.logout();
		await goto('/login');
	}
</script>

<a
	href="#main"
	class="bg-background focus:border-ring sr-only rounded-md p-2 focus:not-sr-only focus:absolute focus:top-2 focus:left-2 focus:border"
>
	{t('shell.skipToContent')}
</a>
<header class="border-b">
	<div class="mx-auto flex max-w-5xl items-center justify-between gap-4 p-3">
		<a href="/dashboard" class="font-semibold">{t('app.name')}</a>
		<div class="flex items-center gap-4">
			<LanguageSwitch />
			<span class="text-muted-foreground text-sm" data-testid="user-name">{session.current?.user.display_name}</span>
			<Button variant="outline" size="sm" onclick={logout} data-testid="logout">{t('shell.logout')}</Button>
		</div>
	</div>
</header>
<main id="main" class="mx-auto max-w-5xl p-4">
	{@render children()}
</main>
