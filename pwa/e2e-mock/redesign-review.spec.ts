import { expect, test, type APIRequestContext, type BrowserContext, type Page } from '@playwright/test';
import { addVirtualAuthenticator } from '../e2e/virtual-authenticator';
import { MOCK_SETUP_TOKEN } from '../mock/api';

// WP-ST7: findings of the independent design review against TimeTrack (docs/handoff/WP-ST7.md), as far as they can be measured.

test.beforeEach(async ({ request }) => {
	expect((await request.post('/api/__mock/reset')).status()).toBe(204);
});

const PHONE = { width: 390, height: 844 };

async function bootstrapWithDocs(page: Page, context: BrowserContext, request: APIRequestContext) {
	await addVirtualAuthenticator(context, page);
	await page.goto('/setup');
	await page.getByLabel('Setup-Token').fill(MOCK_SETUP_TOKEN);
	await page.getByLabel('Kennung').fill('root');
	await page.getByLabel('Anzeigename').fill('Root');
	await page.getByRole('button', { name: 'Passkey anlegen und starten' }).click();
	await expect(page).toHaveURL(/\/dashboard$/);
	await page.goto('/settings/modules');
	await page.getByTestId('module-toggle-dms').click();
	await expect(page.getByTestId('nav-dms')).toBeAttached();
	for (const data of [
		{ title: 'Rechnung Alpha', extraction: { kind: 'invoice', amount: '119.00', due_date: '2000-01-15', reference: 'R-ALPHA' }, suggest: true },
		{ title: 'Vertrag Gamma', extraction: { kind: 'contract', amount: '30.00' } }
	]) {
		expect((await request.post('/api/__mock/dms/seed', { data: { count: 1, ...data } })).status()).toBe(204);
	}
}

test('review 1+2: docs has a lead line; on a phone the filters are folded and the first document is on the first screen as a card', async ({ page, context, request }) => {
	await bootstrapWithDocs(page, context, request);
	await page.setViewportSize(PHONE);
	await page.goto('/dms');
	await expect(page.getByTestId('page-lead')).toBeVisible();
	await expect(page.getByTestId('dms-row')).toHaveCount(2);
	await expect(page.getByTestId('dms-filter-kind')).toBeHidden();
	const first = await page.getByTestId('dms-row').first().boundingBox();
	expect(first!.y).toBeLessThan(PHONE.height - 60);
	await expect(page.getByTestId('dms-row').first().getByTestId('dms-row-amount')).toBeVisible();
	await page.getByTestId('dms-filter-toggle').click();
	await expect(page.getByTestId('dms-filter-kind')).toBeVisible();
	// an active filter is counted on the folded button and the panel stays reachable
	await page.getByTestId('dms-filter-kind').selectOption('invoice');
	await expect(page.getByTestId('dms-filter-toggle')).toContainText('(1)');
	await expect(page.getByTestId('dms-row')).toHaveCount(1);
});

test('review 3+4: dashboard rows are full-height links and the recovery banner has a button', async ({ page, context, request }) => {
	await bootstrapWithDocs(page, context, request);
	await page.goto('/dashboard');
	const row = page.getByTestId('dms-card-overdue-link');
	await expect(row).toBeVisible();
	expect((await row.boundingBox())!.height).toBeGreaterThanOrEqual(40);
	const hint = page.getByTestId('recovery-hint');
	await expect(hint).toContainText('Nur noch wenige Recovery-Codes');
	await expect(hint).toContainText('Es ist nur noch 1 unbenutzter Recovery-Code vorhanden.');
	await expect(hint.getByRole('link', { name: 'Recovery-Codes erzeugen' })).toHaveAttribute('data-slot', 'button');
});

test('review 5: on a phone every button, field and list link is at least 40 px high', async ({ page, context, request }) => {
	test.setTimeout(60_000);
	await bootstrapWithDocs(page, context, request);
	await page.setViewportSize(PHONE);
	for (const path of ['/dashboard', '/dms', '/dms/inbox', '/settings/appearance', '/settings/members', '/settings/sessions']) {
		await page.goto(path);
		await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
		await page.waitForLoadState('networkidle');
		const small = await page.evaluate(() =>
			[...document.querySelectorAll<HTMLElement>('button, select, summary, input:not([type=checkbox]):not([type=radio]):not([type=file]):not([type=hidden]), a[data-slot=button], a[data-touch]')]
				.filter((el) => el.checkVisibility({ visibilityProperty: true }) && !el.closest('[inert], .sr-only'))
				.map((el) => ({ what: el.dataset.testid ?? el.textContent?.trim().slice(0, 30) ?? el.tagName, height: el.getBoundingClientRect().height }))
				.filter((el) => el.height > 0 && el.height < 39.5)
		);
		expect(small, path).toEqual([]);
	}
});

test('review 6+10: the phone menu closes with a button, blocks the page behind it and keeps settings at the bottom; the header names the page', async ({ page, context, request }) => {
	await bootstrapWithDocs(page, context, request);
	await page.setViewportSize(PHONE);
	await page.goto('/dms/inbox');
	await expect(page.getByTestId('header-title')).toHaveText('Eingang');
	await page.getByTestId('menu-toggle').click();
	await expect(page.getByTestId('menu-close')).toBeFocused();
	await expect(page.getByTestId('shell-content')).toHaveAttribute('inert', '');
	await expect(page.getByTestId('drawer-settings')).toBeInViewport();
	await page.getByTestId('menu-close').click();
	await expect(page.getByTestId('sidebar')).not.toBeInViewport();
	await expect(page.getByTestId('shell-content')).not.toHaveAttribute('inert', '');
	await expect(page.getByTestId('menu-toggle')).toBeFocused();
});

test('review 7+8: the start entry is named once and every settings page has its own title', async ({ page, context, request }) => {
	await bootstrapWithDocs(page, context, request);
	await page.goto('/dms');
	await expect(page.getByTestId('nav-dashboard')).toHaveText('Start');
	await expect(page.getByTestId('nav-dms')).toHaveText('Übersicht');
	for (const [path, title] of [
		['/settings/appearance', 'Darstellung'],
		['/settings/profile', 'Profil'],
		['/settings/sessions', 'Sitzungen']
	]) {
		await page.goto(path);
		await expect(page.getByRole('heading', { level: 1 })).toHaveText(title);
		await expect(page.getByTestId('page-lead')).toBeVisible();
	}
});

test('review 13: one suggestion is written in the singular', async ({ page, context, request }) => {
	await bootstrapWithDocs(page, context, request);
	await page.goto('/dms');
	await expect(page.getByTestId('dms-row').filter({ hasText: 'Rechnung Alpha' }).getByTestId('dms-row-suggestions')).toHaveText('1 Vorschlag offen');
});
