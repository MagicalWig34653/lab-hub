import { expect, test } from '@playwright/test';
import { addVirtualAuthenticator } from '../e2e/virtual-authenticator';
import { MOCK_SETUP_TOKEN } from '../mock/api';

// WP-ST6 against the mock backend: the web app is "LAB hub", the DMS module is shown as "docs". Optional screenshots
// (light and dark) go to LH_SHOT_DIR; the app does not switch to dark by itself yet (WP-ST4), so the test sets the class.
const shots = process.env.LH_SHOT_DIR;

test.beforeEach(async ({ request }) => {
	expect((await request.post('/api/__mock/reset')).status()).toBe(204);
});

test('AK-ST6-1 AK-ST6-2 title, brand and module headings in German and English', async ({ page, context }) => {
	await addVirtualAuthenticator(context, page);
	await page.goto('/setup');
	await expect(page).toHaveTitle(/LAB hub$/);
	await page.getByLabel('Setup-Token').fill(MOCK_SETUP_TOKEN);
	await page.getByLabel('Kennung').fill('root');
	await page.getByLabel('Anzeigename').fill('Root');
	await page.getByRole('button', { name: 'Passkey anlegen und starten' }).click();
	await expect(page).toHaveURL(/\/dashboard$/);
	await expect(page).toHaveTitle(/· LAB hub$/);
	const sidebar = page.getByTestId('sidebar');
	await expect(sidebar.getByRole('link', { name: 'LAB hub', exact: true })).toBeVisible();

	await page.getByTestId('nav-settings').click();
	await page.getByTestId('settings-tab-modules').click();
	await expect(page.locator('li[data-module=dms] div.font-medium')).toHaveText('docs');
	await page.getByTestId('module-toggle-dms').click();
	await page.getByTestId('nav-dms').click();

	const heading = page.getByRole('heading', { level: 1 });
	const group = page.getByTestId('nav-group-dms.documents');
	await expect(heading).toHaveText('docs');
	await expect(group).toHaveText('docs');
	await expect(page).toHaveTitle('docs · LAB hub');
	if (shots) {
		await page.screenshot({ path: `${shots}/st6-light.png`, animations: 'disabled' });
		await page.evaluate(() => document.documentElement.classList.add('dark'));
		await page.screenshot({ path: `${shots}/st6-dark.png`, animations: 'disabled' });
	}

	await page.getByTestId('language-switch').first().selectOption('en');
	await expect(heading).toHaveText('docs');
	await expect(group).toHaveText('docs');
	await expect(page).toHaveTitle('docs · LAB hub');
});
