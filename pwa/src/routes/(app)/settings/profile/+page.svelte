<script lang="ts">
	import LanguageSwitch from '#lib/components/app/LanguageSwitch.svelte';
	import * as Card from '#lib/components/ui/card';
	import { t, type MessageKey } from '#lib/i18n/index.svelte';
	import { session } from '#lib/session.svelte';
	import { workspace } from '#lib/workspace.svelte';
</script>

<svelte:head><title>{t('settings.profile')} · {t('app.name')}</title></svelte:head>

<Card.Root>
	<Card.Header><Card.Title><h2 class="text-lg font-semibold">{t('settings.profile')}</h2></Card.Title></Card.Header>
	<Card.Content>
		<dl class="grid grid-cols-[max-content_1fr] gap-x-6 gap-y-2 text-sm" data-testid="profile">
			<dt class="text-muted-foreground">{t('profile.displayName')}</dt>
			<dd>{session.current?.user.display_name}</dd>
			<dt class="text-muted-foreground">{t('profile.handle')}</dt>
			<dd>{session.current?.user.handle}</dd>
			{#if workspace.detail}
				<dt class="text-muted-foreground">{t('profile.tenant')}</dt>
				<dd>{workspace.detail.name}</dd>
				<dt class="text-muted-foreground">{t('profile.role')}</dt>
				<dd data-testid="profile-role">{t(`role.${workspace.detail.role}` as MessageKey)}</dd>
			{/if}
			{#if session.current?.user.is_operator}
				<dt class="text-muted-foreground">{t('profile.operator')}</dt>
				<dd>{t('profile.operatorYes')}</dd>
			{/if}
		</dl>
		<div class="mt-4"><LanguageSwitch /></div>
	</Card.Content>
</Card.Root>
