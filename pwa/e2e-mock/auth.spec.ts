import { expect, test } from '@playwright/test';
import { addVirtualAuthenticator } from '../e2e/virtual-authenticator';
import { MOCK_INVITE_TOKEN, MOCK_RECOVERY_CODE, MOCK_SETUP_TOKEN } from '../mock/api';

// AK-F1-2 against the mock backend: invitation -> passkey (virtual authenticator) -> dashboard.

test.beforeEach(async ({ request }) => {
	const response = await request.post('/api/__mock/reset');
	expect(response.status()).toBe(204);
});

test('AK-F1-2 invitation -> passkey -> dashboard, then logout and passkey login', async ({ page, context }) => {
	const authenticator = await addVirtualAuthenticator(context, page);

	await page.goto(`/invite/${MOCK_INVITE_TOKEN}`);
	await page.getByLabel('Kennung').fill('ada');
	await page.getByLabel('Anzeigename').fill('Ada Test');
	await page.getByRole('button', { name: 'Passkey anlegen' }).click();

	await expect(page).toHaveURL(/\/dashboard$/);
	await expect(page.getByTestId('dashboard-heading')).toContainText('Ada Test');
	await expect(page.getByTestId('tenant-list')).toContainText('Hauptmandant');
	expect(await authenticator.credentialCount()).toBe(1);

	// Reload keeps the session (cookie), so the guard lets us through.
	await page.reload();
	await expect(page.getByTestId('dashboard-heading')).toBeVisible();

	await page.getByTestId('logout').click();
	await expect(page).toHaveURL(/\/login$/);

	await page.getByTestId('login-passkey').click();
	await expect(page).toHaveURL(/\/dashboard$/);
	await expect(page.getByTestId('user-name')).toHaveText('Ada Test');
});

test('an invitation works once; the second use shows the translated error code', async ({ page, context }) => {
	await addVirtualAuthenticator(context, page);
	for (const handle of ['first', 'second']) {
		await page.goto(`/invite/${MOCK_INVITE_TOKEN}`);
		await page.getByLabel('Kennung').fill(handle);
		await page.getByLabel('Anzeigename').fill(handle);
		await page.getByRole('button', { name: 'Passkey anlegen' }).click();
		if (handle === 'first') {
			await expect(page).toHaveURL(/\/dashboard$/);
			await page.getByTestId('logout').click();
		}
	}
	await expect(page.getByTestId('form-error')).toContainText('Die Einladung ist ungültig, abgelaufen oder wurde bereits verwendet.');
});

test('guard sends anonymous deep links to the login with a next target, and returns after login', async ({ page, context }) => {
	await addVirtualAuthenticator(context, page);
	await page.goto(`/invite/${MOCK_INVITE_TOKEN}`);
	await page.getByLabel('Kennung').fill('ada');
	await page.getByLabel('Anzeigename').fill('Ada');
	await page.getByRole('button', { name: 'Passkey anlegen' }).click();
	await expect(page).toHaveURL(/\/dashboard$/);
	await page.getByTestId('logout').click();

	await page.goto('/dashboard');
	await expect(page).toHaveURL(/\/login\?next=%2Fdashboard$/);
	await page.getByTestId('login-passkey').click();
	await expect(page).toHaveURL(/\/dashboard$/);
});

test('F1-3 deep links fall back to the app shell (unknown path renders the app)', async ({ page }) => {
	const response = await page.goto('/recover');
	expect(response?.status()).toBe(200);
	await expect(page.getByRole('heading', { name: 'Anmeldung mit Recovery-Code' })).toBeVisible();
});

test('bootstrap with setup token creates the first user and tenant', async ({ page, context }) => {
	await addVirtualAuthenticator(context, page);
	await page.goto('/setup');
	await page.getByLabel('Setup-Token').fill('wrong-token');
	await page.getByLabel('Kennung').fill('root');
	await page.getByLabel('Anzeigename').fill('Root');
	await page.getByRole('button', { name: 'Passkey anlegen und starten' }).click();
	await expect(page.getByTestId('form-error')).toContainText('Das Setup-Token ist ungültig.');

	await page.getByLabel('Setup-Token').fill(MOCK_SETUP_TOKEN);
	await page.getByRole('button', { name: 'Passkey anlegen und starten' }).click();
	await expect(page).toHaveURL(/\/dashboard$/);
	await expect(page.getByTestId('dashboard-heading')).toContainText('Root');
});

test('recovery code gives an emergency session that is upgraded by a new passkey', async ({ page, context }) => {
	await addVirtualAuthenticator(context, page);
	await page.goto('/setup');
	await page.getByLabel('Setup-Token').fill(MOCK_SETUP_TOKEN);
	await page.getByLabel('Kennung').fill('root');
	await page.getByLabel('Anzeigename').fill('Root');
	await page.getByRole('button', { name: 'Passkey anlegen und starten' }).click();
	await expect(page).toHaveURL(/\/dashboard$/);
	await page.getByTestId('logout').click();

	await page.goto('/recover');
	await page.getByLabel('Kennung').fill('root');
	await page.getByLabel('Recovery-Code').fill('wrong');
	await page.getByRole('button', { name: 'Anmelden' }).click();
	await expect(page.getByTestId('form-error')).toContainText('Anmeldung fehlgeschlagen.');

	await page.getByLabel('Recovery-Code').fill(MOCK_RECOVERY_CODE);
	await page.getByRole('button', { name: 'Anmelden' }).click();
	await expect(page).toHaveURL(/\/dashboard$/);
	await expect(page.getByTestId('recovery-banner')).toBeVisible();

	await page.getByTestId('recovery-add-passkey').click();
	await expect(page.getByTestId('recovery-banner')).toBeHidden();
	await expect(page.getByTestId('tenant-list')).toContainText('Hauptmandant');
});

test('language switch changes the UI text', async ({ page }) => {
	await page.goto('/login');
	await page.getByTestId('language-switch').selectOption('en');
	await expect(page.getByRole('heading', { name: 'Sign in' })).toBeVisible();
	await expect(page.getByTestId('login-passkey')).toHaveText('Sign in with passkey');
});
