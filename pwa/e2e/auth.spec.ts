import { expect, test } from '@playwright/test';
import { addVirtualAuthenticator } from './virtual-authenticator';

// AK-F1-2 against the real backend: setup token -> first user, invitation -> passkey -> dashboard, passkey login.
// Needs a fresh database: the bootstrap window closes after the first user.
const setupToken = process.env.E2E_SETUP_TOKEN;

test.skip(!setupToken, 'E2E_SETUP_TOKEN not set: real-backend E2E needs a fresh backend started with SETUP_TOKEN');

test('AK-F1-2 bootstrap, invitation -> passkey -> dashboard, passkey login', async ({ browser }) => {
	// 1. Operator: bootstrap with the setup token.
	const ownerContext = await browser.newContext();
	const owner = await ownerContext.newPage();
	await addVirtualAuthenticator(ownerContext, owner);
	await owner.goto('/setup');
	await owner.getByLabel('Setup-Token').fill(setupToken!);
	await owner.getByLabel('Kennung').fill('owner');
	await owner.getByLabel('Anzeigename').fill('Owner Test');
	await owner.getByRole('button', { name: 'Passkey anlegen und starten' }).click();
	await expect(owner).toHaveURL(/\/dashboard$/);
	await expect(owner.getByTestId('tenant-list')).toBeVisible();

	// 2. Owner creates an invitation through the API (the invitation UI follows with WP-F2).
	const session = (await (await ownerContext.request.get('/api/v1/auth/session')).json()) as {
		csrf_token: string;
		memberships: { tenant_id: string }[];
	};
	const created = await ownerContext.request.post(`/api/v1/tenants/${session.memberships[0].tenant_id}/invitations`, {
		headers: { 'X-CSRF-Token': session.csrf_token },
		data: {}
	});
	expect(created.status()).toBe(201);
	const invitation = (await created.json()) as { token: string };

	// 3. Invited user in a fresh browser context: invitation -> passkey -> dashboard.
	const guestContext = await browser.newContext();
	const guest = await guestContext.newPage();
	await addVirtualAuthenticator(guestContext, guest);
	await guest.goto(`/invite/${invitation.token}`);
	await guest.getByLabel('Kennung').fill('guest');
	await guest.getByLabel('Anzeigename').fill('Guest Test');
	await guest.getByRole('button', { name: 'Passkey anlegen' }).click();
	await expect(guest).toHaveURL(/\/dashboard$/);
	await expect(guest.getByTestId('dashboard-heading')).toContainText('Guest Test');

	// 4. Sign out and back in with the passkey.
	await guest.getByTestId('logout').click();
	await expect(guest).toHaveURL(/\/login$/);
	await guest.getByTestId('login-passkey').click();
	await expect(guest).toHaveURL(/\/dashboard$/);

	// 5. The invitation cannot be used twice.
	const again = await guestContext.newPage();
	await again.goto(`/invite/${invitation.token}`);
	await again.getByLabel('Kennung').fill('guest2');
	await again.getByLabel('Anzeigename').fill('Guest Two');
	await again.getByRole('button', { name: 'Passkey anlegen' }).click();
	await expect(again.getByTestId('form-error')).toBeVisible();

	await ownerContext.close();
	await guestContext.close();
});
