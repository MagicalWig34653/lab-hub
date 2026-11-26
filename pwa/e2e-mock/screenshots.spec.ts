import { expect, test, type Page } from '@playwright/test';
import { addVirtualAuthenticator } from '../e2e/virtual-authenticator';
import { MOCK_SETUP_TOKEN } from '../mock/api';

// Design review pictures (WP-ST7), synthetic data only. Runs only with SCREENSHOT_DIR set:
//   VITE_MOCK=1 npm run build && SCREENSHOT_DIR=../docs/screenshots/redesign npx playwright test -c playwright.mock.config.ts e2e-mock/screenshots.spec.ts
const dir = process.env.SCREENSHOT_DIR;

const devices = [
	{ name: 'desktop', viewport: { width: 1440, height: 900 } },
	{ name: 'phone', viewport: { width: 390, height: 844 } }
] as const;

test.skip(!dir, 'SCREENSHOT_DIR not set');

async function shot(page: Page, name: string) {
	await page.waitForLoadState('networkidle');
	await page.mouse.move(0, 0);
	await page.screenshot({ path: `${dir}/${name}.png`, animations: 'disabled' });
}

for (const device of devices) {
	for (const mode of ['light', 'dark'] as const) {
		test(`screenshots ${device.name} ${mode}`, async ({ page, context, request }) => {
			test.setTimeout(90_000);
			expect((await request.post('/api/__mock/reset')).status()).toBe(204);
			await page.setViewportSize(device.viewport);
			await page.emulateMedia({ colorScheme: mode });
			await addVirtualAuthenticator(context, page);
			const name = (page_: string) => `${page_}-${device.name}-${mode}`;

			await page.goto('/login');
			await expect(page.getByTestId('login-passkey')).toBeVisible();
			await shot(page, name('login'));

			await page.goto('/setup');
			await page.getByLabel('Setup-Token').fill(MOCK_SETUP_TOKEN);
			await page.getByLabel('Kennung').fill('root');
			await page.getByLabel('Anzeigename').fill('Robin Beispiel');
			await page.getByRole('button', { name: 'Passkey anlegen und starten' }).click();
			await expect(page).toHaveURL(/\/dashboard$/);
			await page.goto('/settings/modules');
			await page.getByTestId('module-toggle-dms').click();
			await expect(page.getByTestId('nav-dms')).toBeAttached();
			const seed = async (data: Record<string, unknown>) =>
				expect((await request.post('/api/__mock/dms/seed', { data: { count: 1, ...data } })).status()).toBe(204);
			await seed({ title: 'Rechnung Musterversorger', extraction: { kind: 'invoice', amount: '119.00', due_date: '2000-01-15', reference: 'R-2026-014' }, suggest: true });
			await seed({ title: 'Rechnung Beispielhandel', extraction: { kind: 'invoice', amount: '450.50', due_date: '2099-01-15', reference: 'R-2026-015' } });
			await seed({ title: 'Mietvertrag Muster', extraction: { kind: 'contract', amount: '30.00' } });
			await seed({ title: 'Brief der Beispielstelle', extraction: { kind: 'letter', kind_certain: false } });

			await page.goto('/dashboard');
			await expect(page.getByTestId('kpi-recovery')).toBeVisible();
			await shot(page, name('dashboard'));

			await page.goto('/dms');
			await expect(page.getByTestId('dms-row')).toHaveCount(4);
			await shot(page, name('dms'));

			for (const [route, shotName] of [
				['/dms/inbox', 'inbox'],
				['/dms/rules', 'rules'],
				['/dms/masters', 'masters'],
				['/settings/members', 'members']
			]) {
				await page.goto(route);
				await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
				await shot(page, name(shotName));
			}

			await page.goto('/settings/appearance');
			await expect(page.getByTestId('accent-teal')).toBeVisible();
			await shot(page, name('appearance'));

			// a second accent shows that the whole frame follows the user's colour
			await page.getByTestId('accent-violet').click();
			await expect(page.getByTestId('accent-violet')).toHaveAttribute('aria-checked', 'true');
			await page.goto('/dashboard');
			await expect(page.getByTestId('kpi-recovery')).toBeVisible();
			await shot(page, name('dashboard-violet'));

			if (device.name === 'phone') {
				await page.getByTestId('menu-toggle').click();
				await expect(page.getByTestId('sidebar')).toBeInViewport();
				await shot(page, name('menu'));
			}
		});
	}
}
