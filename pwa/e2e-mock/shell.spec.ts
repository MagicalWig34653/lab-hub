import { expect, test, type Page } from '@playwright/test';
import { addVirtualAuthenticator } from '../e2e/virtual-authenticator';
import { MOCK_SETUP_TOKEN } from '../mock/api';

// WP-F2 against the mock backend: tenant switch, module switch, recovery codes, settings. The mock owns two synthetic
// tenants: "Hauptmandant" (owner) and "Zweitmandant" (member).

test.beforeEach(async ({ request }) => {
	expect((await request.post('/api/__mock/reset')).status()).toBe(204);
});

async function bootstrap(page: Page, context: Parameters<typeof addVirtualAuthenticator>[0]) {
	const authenticator = await addVirtualAuthenticator(context, page);
	await page.goto('/setup');
	await page.getByLabel('Setup-Token').fill(MOCK_SETUP_TOKEN);
	await page.getByLabel('Kennung').fill('root');
	await page.getByLabel('Anzeigename').fill('Root');
	await page.getByRole('button', { name: 'Passkey anlegen und starten' }).click();
	await expect(page).toHaveURL(/\/dashboard$/);
	return authenticator;
}

test('AK-F2-1 menu shows only active modules; owner switches a module on and off (AK-F2-2)', async ({ page, context }) => {
	await bootstrap(page, context);
	const sidebar = page.getByTestId('sidebar');
	await expect(sidebar).toContainText('Übersicht');
	await expect(page.getByTestId('nav-dms')).toHaveCount(0);

	await page.getByTestId('nav-settings').click();
	await page.getByTestId('settings-tab-modules').click();
	await page.getByTestId('module-toggle-dms').click();
	await expect(page.getByTestId('nav-dms')).toBeVisible();
	await expect(page.getByTestId('nav-dms')).toHaveText('Dokumente');

	await page.getByTestId('nav-dms').click();
	await expect(page).toHaveURL(/\/dms$/);
	await expect(page.getByTestId('dms-search')).toBeVisible();
	await expect(page.getByTestId('nav-dms')).toHaveAttribute('aria-current', 'page');

	// The change survives a reload: it is backend state, not UI state.
	await page.reload();
	await expect(page.getByTestId('nav-dms')).toBeVisible();

	await page.goto('/settings/modules');
	await page.getByTestId('module-toggle-dms').click();
	await expect(page.getByTestId('nav-dms')).toHaveCount(0);

	// Direct call of a disabled module route shows ModuleDisabled.
	await page.goto('/dms');
	await expect(page.getByTestId('module-disabled')).toBeVisible();
});

test('AK-F2-2 a module change made elsewhere shows up when the tab becomes visible again', async ({ page, context, request }) => {
	await bootstrap(page, context);
	await expect(page.getByTestId('nav-dms')).toHaveCount(0);
	// Switch the module in the backend outside of the UI (the mock has one
	// user; the page's own session cookie and CSRF token are reused).
	const cookies = await context.cookies();
	const session = await (await page.request.get('/api/v1/auth/session')).json();
	const tenant = session.memberships[0].tenant_id;
	const response = await request.put(`/api/v1/tenants/${tenant}/modules/dms`, {
		data: { enabled: true },
		headers: {
			'x-csrf-token': session.csrf_token,
			cookie: cookies.map((c) => `${c.name}=${c.value}`).join('; ')
		}
	});
	expect(response.status()).toBe(200);
	await page.evaluate(() => {
		Object.defineProperty(document, 'visibilityState', { value: 'visible', configurable: true });
		document.dispatchEvent(new Event('visibilitychange'));
	});
	await expect(page.getByTestId('nav-dms')).toBeVisible();
});

test('tenant switch changes role, permissions, modules and remembers the choice', async ({ page, context }) => {
	await bootstrap(page, context);
	// Enable DMS in the main tenant only.
	await page.goto('/settings/modules');
	await page.getByTestId('module-toggle-dms').click();
	await expect(page.getByTestId('nav-dms')).toBeVisible();

	await page.goto('/settings/profile');
	await expect(page.getByTestId('tenant-switch')).toBeVisible();
	await expect(page.getByTestId('profile-role')).toHaveText('Inhaber');
	await expect(page.getByTestId('settings-tab-modules')).toBeVisible();
	await expect(page.getByTestId('settings-tab-members')).toBeVisible();

	await page.getByTestId('tenant-switch').selectOption({ label: 'Zweitmandant' });
	await expect(page.getByTestId('profile-role')).toHaveText('Mitglied');
	await expect(page.getByTestId('nav-dms')).toHaveCount(0);
	// Member: no module management tab; members may be read but not managed.
	await expect(page.getByTestId('settings-tab-modules')).toHaveCount(0);
	await expect(page.getByTestId('settings-tab-members')).toBeVisible();
	await page.goto('/settings/modules');
	await expect(page.getByTestId('modules-forbidden')).toBeVisible();
	await page.goto('/settings/members');
	await expect(page.getByTestId('member-list')).toContainText('Root');
	await expect(page.getByTestId('invite-create')).toHaveCount(0);

	// The remembered tenant is used after a reload.
	await page.reload();
	await expect(page.getByTestId('tenant-switch')).toHaveValue(
		await page.getByTestId('tenant-switch').locator('option', { hasText: 'Zweitmandant' }).getAttribute('value') as string
	);

	await page.getByTestId('tenant-switch').selectOption({ label: 'Hauptmandant' });
	await expect(page.getByTestId('nav-dms')).toBeVisible();
});

test('recovery codes: hint, one-time display with copy and download, then gone', async ({ page, context }) => {
	await context.grantPermissions(['clipboard-read', 'clipboard-write']);
	await bootstrap(page, context);
	// Only one unused code left in the mock: the dashboard asks for new ones.
	await expect(page.getByTestId('recovery-hint')).toBeVisible();
	await page.getByTestId('recovery-hint').getByRole('link').click();
	await expect(page).toHaveURL(/\/settings\/security$/);

	await expect(page.getByTestId('recovery-remaining')).toContainText('1');
	await page.getByTestId('recovery-generate').click();
	// Replacing existing codes needs a second, explicit click.
	await expect(page.getByTestId('recovery-codes')).toContainText('werden ungültig');
	await page.getByTestId('recovery-generate').click();

	await expect(page.getByTestId('recovery-codes-once')).toBeVisible();
	const items = page.getByTestId('recovery-code-list').locator('li');
	await expect(items).toHaveCount(8);
	const codes = await items.allTextContents();

	await page.getByTestId('recovery-copy').click();
	await expect(page.getByRole('status').filter({ hasText: 'Kopiert' })).toBeVisible();
	expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(codes.join('\n'));

	const download = page.waitForEvent('download');
	await page.getByTestId('recovery-download').click();
	expect((await download).suggestedFilename()).toBe('lab-hub-recovery-codes.txt');

	// Closing needs the explicit confirmation; afterwards the codes are not shown again.
	await expect(page.getByTestId('recovery-done')).toBeDisabled();
	await page.getByTestId('recovery-confirm').check();
	await page.getByTestId('recovery-done').click();
	await expect(page.getByTestId('recovery-code-list')).toHaveCount(0);
	await expect(page.getByTestId('recovery-remaining')).toContainText('8');
	await page.reload();
	await expect(page.getByTestId('recovery-code-list')).toHaveCount(0);

	await page.goto('/dashboard');
	await expect(page.getByTestId('recovery-hint')).toHaveCount(0);
});

test('a generated recovery code signs in as an emergency session without app navigation', async ({ page, context }) => {
	await bootstrap(page, context);
	await page.goto('/settings/security');
	await page.getByTestId('recovery-generate').click();
	await page.getByTestId('recovery-generate').click();
	const first = (await page.getByTestId('recovery-code-list').locator('li').first().textContent())!.trim();
	await page.getByTestId('recovery-confirm').check();
	await page.getByTestId('recovery-done').click();
	await page.getByTestId('logout').click();

	await page.goto('/recover');
	await page.getByLabel('Kennung').fill('root');
	await page.getByLabel('Recovery-Code').fill(first);
	await page.getByRole('button', { name: 'Anmelden' }).click();
	await expect(page.getByTestId('recovery-banner')).toBeVisible();
	// Emergency session: no navigation into the app.
	await expect(page.getByTestId('sidebar')).toHaveCount(0);
});

test('passkeys: add a second one, remove it; the last one cannot be removed', async ({ page, context }) => {
	const authenticator = await bootstrap(page, context);
	await page.goto('/settings/security');
	const list = page.getByTestId('passkey-list');
	await expect(list.locator('li')).toHaveCount(1);
	await expect(list.getByRole('button', { name: /entfernen/ })).toBeDisabled();

	await page.getByLabel('Name des neuen Passkeys').fill('Zweitgerät');
	await page.getByTestId('passkey-add').click();
	await expect(list.locator('li')).toHaveCount(2);
	await expect(list).toContainText('Zweitgerät');
	expect(await authenticator.credentialCount()).toBe(2);

	await list.getByRole('button', { name: 'Passkey Zweitgerät entfernen' }).click();
	await expect(list.locator('li')).toHaveCount(1);
});

test('sessions: list shows the current device; sign out on all devices ends the session', async ({ page, context }) => {
	await bootstrap(page, context);
	await page.goto('/settings/sessions');
	await expect(page.getByTestId('session-list').locator('li')).toHaveCount(1);
	await expect(page.getByTestId('session-list')).toContainText('aktuelle Sitzung');

	await page.getByTestId('logout-all').click();
	await expect(page.getByTestId('logout-all')).toContainText('Ja, überall abmelden');
	await page.getByTestId('logout-all').click();
	await expect(page).toHaveURL(/\/login/);
	await page.goto('/dashboard');
	await expect(page).toHaveURL(/\/login\?next=/);
});

test('members: owner creates a one-time invitation link and changes a role guard (last owner)', async ({ page, context }) => {
	await bootstrap(page, context);
	await page.goto('/settings/members');
	await expect(page.getByTestId('member-list')).toContainText('Root');
	await page.getByTestId('invite-create').click();
	await expect(page.getByTestId('invite-result')).toBeVisible();
	await expect(page.getByTestId('invite-link')).toContainText('/invite/');

	// The last owner cannot be demoted: the backend's answer is shown translated.
	await page.getByLabel('Rolle von Root').selectOption('member');
	await expect(page.getByTestId('error-banner')).toContainText('letzte Inhaber');
});

test('shell is usable in English and has the sidebar landmark', async ({ page, context }) => {
	await bootstrap(page, context);
	await page.getByTestId('language-switch').first().selectOption('en');
	await expect(page.getByRole('navigation', { name: 'Main navigation' })).toContainText('Settings');
	await expect(page).toHaveURL(/\/dashboard$/);
});
