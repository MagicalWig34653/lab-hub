<script lang="ts">
	import { tenantApi, type InvitationCreated, type Member, type Role } from '#lib/api/client';
	import ErrorBanner from '#lib/components/app/ErrorBanner.svelte';
	import * as Alert from '#lib/components/ui/alert';
	import { Button } from '#lib/components/ui/button';
	import * as Card from '#lib/components/ui/card';
	import { Label } from '#lib/components/ui/label';
	import { formatDateTime, invitationLink } from '#lib/format';
	import { errorMessage, i18n, t, type MessageKey } from '#lib/i18n/index.svelte';
	import { session } from '#lib/session.svelte';
	import { workspace } from '#lib/workspace.svelte';

	const roles: Role[] = ['owner', 'accountant', 'member', 'tax_advisor', 'customer_viewer'];

	let members = $state<Member[]>([]);
	let error = $state<string | null>(null);
	let inviteRole = $state<Role>('member');
	let invitation = $state<{ created: InvitationCreated; link: string } | null>(null);
	let copied = $state(false);

	const canRead = $derived(workspace.can('tenant.member.read'));
	const canInvite = $derived(workspace.can('tenant.member.invite'));
	const canManage = $derived(workspace.can('tenant.member.manage'));

	// Reloads whenever the active tenant (or its permissions) change.
	$effect(() => {
		const tenant = workspace.activeId;
		if (tenant && canRead) void load(tenant);
	});

	async function load(tenant: string) {
		try {
			const items = (await tenantApi.members(tenant)).items;
			if (tenant === workspace.activeId) members = items;
		} catch (e) {
			error = errorMessage(e);
		}
	}

	async function changeRole(member: Member, role: Role) {
		const tenant = workspace.activeId;
		if (!tenant) return;
		error = null;
		try {
			await tenantApi.changeRole(tenant, member.user_id, role);
		} catch (e) {
			error = errorMessage(e);
		}
		await load(tenant);
	}

	async function remove(member: Member) {
		const tenant = workspace.activeId;
		if (!tenant) return;
		error = null;
		try {
			await tenantApi.removeMember(tenant, member.user_id);
		} catch (e) {
			error = errorMessage(e);
		}
		await load(tenant);
	}

	async function invite(event: SubmitEvent) {
		event.preventDefault();
		const tenant = workspace.activeId;
		if (!tenant) return;
		error = null;
		copied = false;
		try {
			const created = await tenantApi.invite(tenant, { role: inviteRole });
			invitation = { created, link: invitationLink(created.link, created.token, location.origin) };
		} catch (e) {
			error = errorMessage(e);
		}
	}

	async function copyLink() {
		try {
			await navigator.clipboard.writeText(invitation?.link ?? '');
			copied = true;
		} catch {
			copied = false;
		}
	}
</script>

<svelte:head><title>{t('settings.members')} · {t('app.name')}</title></svelte:head>

{#if !canRead}
	<Alert.Root data-testid="members-forbidden"><Alert.Description>{t('error.forbidden')}</Alert.Description></Alert.Root>
{:else}
	<div class="space-y-6">
		<Card.Root>
			<Card.Header><Card.Title><h2 class="text-lg font-semibold">{t('members.title')}</h2></Card.Title></Card.Header>
			<Card.Content class="space-y-4">
				<ErrorBanner message={error} />
				<ul class="divide-y" data-testid="member-list">
					{#each members as member (member.user_id)}
						<li class="flex flex-wrap items-center justify-between gap-2 py-2" data-handle={member.handle}>
							<div>
								<div class="font-medium">{member.display_name}</div>
								<div class="text-muted-foreground text-xs">
									{member.handle} · {t('members.since', { date: formatDateTime(member.created_at, i18n.locale) })}
								</div>
							</div>
							<div class="flex items-center gap-2">
								{#if canManage}
									<select
										class="border-input bg-background h-8 rounded-md border px-2 text-sm"
										value={member.role}
										aria-label={t('members.roleOf', { name: member.display_name })}
										onchange={(e) => changeRole(member, e.currentTarget.value as Role)}
									>
										{#each roles as role (role)}
											<option value={role}>{t(`role.${role}` as MessageKey)}</option>
										{/each}
									</select>
									{#if member.user_id !== session.current?.user.id}
										<Button variant="destructive" size="sm" onclick={() => remove(member)} aria-label={t('members.removeNamed', { name: member.display_name })}>
											{t('members.remove')}
										</Button>
									{/if}
								{:else}
									<span class="text-sm">{t(`role.${member.role}` as MessageKey)}</span>
								{/if}
							</div>
						</li>
					{/each}
				</ul>
			</Card.Content>
		</Card.Root>

		{#if canInvite}
			<Card.Root>
				<Card.Header>
					<Card.Title><h2 class="text-lg font-semibold">{t('invitations.title')}</h2></Card.Title>
					<Card.Description>{t('invitations.description')}</Card.Description>
				</Card.Header>
				<Card.Content class="space-y-4">
					<form class="flex flex-wrap items-end gap-2" onsubmit={invite}>
						<div class="space-y-2">
							<Label for="invite-role">{t('invitations.role')}</Label>
							<select id="invite-role" class="border-input bg-background h-8 rounded-md border px-2 text-sm" bind:value={inviteRole}>
								{#each roles as role (role)}
									<option value={role}>{t(`role.${role}` as MessageKey)}</option>
								{/each}
							</select>
						</div>
						<Button type="submit" data-testid="invite-create">{t('invitations.create')}</Button>
					</form>
					{#if invitation}
						<Alert.Root data-testid="invite-result">
							<Alert.Title>{t('invitations.onceTitle')}</Alert.Title>
							<Alert.Description>
								<p>{t('invitations.onceText', { date: formatDateTime(invitation.created.expires_at, i18n.locale) })}</p>
								<code class="bg-muted mt-2 block rounded p-2 text-xs break-all" data-testid="invite-link">{invitation.link}</code>
								<div class="mt-2 flex items-center gap-2">
									<Button variant="outline" size="sm" onclick={copyLink}>{t('invitations.copy')}</Button>
									<span role="status" class="text-sm">{#if copied}{t('invitations.copied')}{/if}</span>
								</div>
							</Alert.Description>
						</Alert.Root>
					{/if}
				</Card.Content>
			</Card.Root>
		{/if}
	</div>
{/if}
