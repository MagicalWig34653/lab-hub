import AxeBuilder from '@axe-core/playwright';
import { expect, test, type BrowserContext, type Page } from '@playwright/test';
import { addVirtualAuthenticator } from '../e2e/virtual-authenticator';
import { MOCK_INVITE_TOKEN, MOCK_SETUP_TOKEN } from '../mock/api';

// WP-ST7 (redesign + accent per user) and WP-ST4 (system/light/dark) against the mock backend.

test.beforeEach(async ({ request }) => {
	expect((await request.post('/api/__mock/reset')).status()).toBe(204);
});

async function bootstrap(page: Page, context: BrowserContext) {
	await addVirtualAuthenticator(context, page);
	await page.goto('/setup');
	await page.getByLabel('Setup-Token').fill(MOCK_SETUP_TOKEN);
	await page.getByLabel('Kennung').fill('root');
	await page.getByLabel('Anzeigename').fill('Root');
	await page.getByRole('button', { name: 'Passkey anlegen und starten' }).click();
	await expect(page).toHaveURL(/\/dashboard$/);
}

const accentOf = (page: Page) => page.evaluate(() => document.documentElement.style.getPropertyValue('--ui-accent'));
const isDark = (page: Page) => page.evaluate(() => document.documentElement.classList.contains('dark'));

async function expectNoSeriousA11y(page: Page) {
	const result = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
	const bad = result.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
	expect(bad.map((v) => `${page.url()} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).join(' | ')}`)).toEqual([]);
}

test('AK-ST7-5 each user keeps an own accent colour, across reload and sign-in', async ({ page, context, browser, baseURL }) => {
	await bootstrap(page, context);
	await expect.poll(() => accentOf(page)).toBe('#2563eb');

	await page.getByTestId('header-appearance').click();
	await expect(page).toHaveURL(/\/settings\/appearance$/);
	await page.getByTestId('accent-teal').click();
	await expect(page.getByTestId('accent-teal')).toHaveAttribute('aria-checked', 'true');
	await expect.poll(() => accentOf(page)).toBe('#0d9488');

	// The colour lives in the account: a reload without the browser cache shows it again.
	await page.evaluate(() => localStorage.clear());
	await page.reload();
	await expect.poll(() => accentOf(page)).toBe('#0d9488');

	// A second user (own browser) starts with the default and picks an own colour.
	const otherContext = await browser.newContext({ baseURL, locale: 'de-DE' });
	const other = await otherContext.newPage();
	await addVirtualAuthenticator(otherContext, other);
	await other.goto(`/invite/${MOCK_INVITE_TOKEN}`);
	await other.getByLabel('Kennung').fill('ada');
	await other.getByLabel('Anzeigename').fill('Ada Test');
	await other.getByRole('button', { name: 'Passkey anlegen' }).click();
	await expect(other).toHaveURL(/\/dashboard$/);
	await expect.poll(() => accentOf(other)).toBe('#2563eb');
	await other.goto('/settings/appearance');
	await other.getByTestId('accent-custom').fill('#7c3aed');
	await other.getByTestId('accent-custom-apply').click();
	await expect.poll(() => accentOf(other)).toBe('#7c3aed');
	await otherContext.close();

	await page.reload();
	await expect.poll(() => accentOf(page)).toBe('#0d9488');

	// Signing out removes the personal colour from the login page.
	await page.getByTestId('logout').click();
	await expect(page).toHaveURL(/\/login$/);
	await expect.poll(() => accentOf(page)).toBe('#2563eb');
	await page.getByTestId('login-passkey').click();
	await expect(page).toHaveURL(/\/dashboard$/);
	await expect.poll(() => accentOf(page)).toBe('#0d9488');

	await page.goto('/settings/appearance');
	await page.getByTestId('accent-reset').click();
	await expect.poll(() => accentOf(page)).toBe('#2563eb');
});

test('AK-ST4-1/2 system by default, manual dark stays per device and applies before the app starts', async ({ page, context }) => {
	await page.emulateMedia({ colorScheme: 'dark' });
	await bootstrap(page, context);
	await expect.poll(() => isDark(page)).toBe(true);
	await page.emulateMedia({ colorScheme: 'light' });
	await expect.poll(() => isDark(page)).toBe(false);

	await page.goto('/settings/appearance');
	await page.getByTestId('theme-dark').click();
	await expect.poll(() => isDark(page)).toBe(true);
	await page.reload();
	await expect.poll(() => isDark(page)).toBe(true);

	// Without the application bundle only the early script runs: the page is already dark (no flash of light).
	await page.route('**/_app/**', (route) => route.abort());
	await page.reload();
	await expect.poll(() => isDark(page)).toBe(true);
	await page.unroute('**/_app/**');

	await page.reload();
	await page.getByTestId('theme-system').click();
	await expect.poll(() => isDark(page)).toBe(false);
});

const CORE_PAGES = ['/dashboard', '/settings/appearance', '/settings/profile', '/settings/security', '/dms', '/dms/inbox'];

async function enableDms(page: Page) {
	await page.goto('/settings/modules');
	await page.getByTestId('module-toggle-dms').click();
	await expect(page.getByTestId('nav-dms')).toBeAttached();
}

test('AK-ST4-3 core pages have no serious accessibility findings in light and dark, also with a light accent', async ({ page, context }) => {
	test.setTimeout(90_000);
	await bootstrap(page, context);
	await enableDms(page);
	await page.goto('/settings/appearance');
	for (const accent of ['accent-blue', 'accent-amber']) {
		await page.goto('/settings/appearance');
		await page.getByTestId(accent).click();
		await expect(page.getByTestId(accent)).toHaveAttribute('aria-checked', 'true');
		for (const mode of ['light', 'dark'] as const) {
			await page.goto('/settings/appearance');
			await page.getByTestId(`theme-${mode}`).click();
			for (const path of CORE_PAGES) {
				await page.goto(path);
				await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
				await page.waitForLoadState('networkidle');
				await expectNoSeriousA11y(page);
			}
		}
	}
});

test('AK-ST7-6 on a 390 px phone no core page scrolls sideways and the menu is a drawer', async ({ page, context }) => {
	await bootstrap(page, context);
	await enableDms(page);
	await page.setViewportSize({ width: 390, height: 844 });
	for (const path of CORE_PAGES) {
		await page.goto(path);
		await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
		await page.waitForLoadState('networkidle');
		const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
		expect(overflow, path).toBeLessThanOrEqual(0);
	}
	await page.getByTestId('menu-toggle').click();
	await expect(page.getByTestId('sidebar')).toBeInViewport();
});
