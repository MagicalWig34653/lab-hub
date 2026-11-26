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
	// one header row, also with a long page name
	for (const path of ['/settings/appearance', '/settings/security', '/dms/scanner', '/dms/inbox']) {
		await page.goto(path);
		await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
		expect((await page.locator('header').boundingBox())!.height, path).toBeLessThanOrEqual(64);
	}
	await page.getByTestId('menu-toggle').click();
	// the footer buttons keep their labels inside
	for (const button of [page.getByTestId('drawer-settings'), page.getByTestId('drawer-logout')]) {
		expect(await button.evaluate((el) => el.scrollWidth - el.clientWidth)).toBeLessThanOrEqual(0);
		expect(await button.evaluate((el) => el.getBoundingClientRect().width - el.scrollWidth)).toBeGreaterThanOrEqual(0);
		expect(await button.evaluate((el) => {
			const range = document.createRange();
			range.selectNodeContents(el);
			return el.getBoundingClientRect().width - range.getBoundingClientRect().width;
		})).toBeGreaterThanOrEqual(16);
	}
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

test('own finding: the inbox on a phone keeps the suggestion text wide, above its buttons, with singular and spacing', async ({ page, context, request }) => {
	await bootstrapWithDocs(page, context, request);
	await page.setViewportSize(PHONE);
	await page.goto('/dms/inbox');
	const card = page.getByTestId('suggestion-card').first();
	const text = await card.getByTestId('suggestion-reason').boundingBox();
	expect(text!.width).toBeGreaterThanOrEqual(240);
	const accept = await card.getByTestId('suggestion-accept').boundingBox();
	expect(accept!.y).toBeGreaterThanOrEqual(text!.y + text!.height);
	expect((await card.getByTestId('suggestion-change').boundingBox())!.height).toBeGreaterThanOrEqual(40);
	await expect(page.getByRole('heading', { name: '1 offener Vorschlag', exact: true })).toBeVisible();
	await expect(page.getByTestId('inbox-attention')).toContainText('15.01.2000 (überfällig)');
});

test('re-check 1: the active settings entry is scrolled into view in the sidebar', async ({ page, context, request }) => {
	await bootstrapWithDocs(page, context, request);
	await page.setViewportSize({ width: 1440, height: 900 });
	await page.goto('/settings/members');
	await expect(page.getByTestId('settings-tab-members')).toHaveAttribute('aria-current', 'page');
	await expect(page.getByTestId('settings-tab-members')).toBeInViewport({ ratio: 1 });
});

test('re-check 2: sub pages share the card pattern for lists and empty states; the new action sits in the page head', async ({ page, context, request }) => {
	await bootstrapWithDocs(page, context, request);
	const radius = (testid: string) =>
		page.getByTestId(testid).evaluate((el) => {
			const card = el.closest<HTMLElement>('.panel');
			return card ? getComputedStyle(card).borderTopLeftRadius : null;
		});
	for (const [path, testid] of [
		['/dms/rules', 'rules-empty'],
		['/dms/duplicates', 'duplicates-empty'],
		['/dms/exports', 'exports-empty'],
		['/dms/masters', 'masters-table'],
		['/dms/tokens', 'tokens-empty'],
		['/dms/trash', 'trash-empty'],
		['/dms/sources', 'sources-empty'],
		['/dms/integrity', 'integrity-empty'],
		['/dms/scanner', 'scanner-curl']
	]) {
		await page.goto(path);
		await expect(page.getByTestId(testid)).toBeVisible();
		expect(await radius(testid), path).toBe('10px');
	}
	await page.goto('/dms/masters');
	await expect(page.getByTestId('masters-new')).toBeVisible();
	expect(await page.getByTestId('masters-new').evaluate((el) => Boolean(el.closest('.page-actions')))).toBe(true);
});

test('re-check 3-6: phone card lists have one line between rows and a title; inbox links look like links; the tenant name is not cut', async ({ page, context, request }) => {
	await bootstrapWithDocs(page, context, request);
	await page.setViewportSize(PHONE);
	await page.goto('/dms/masters');
	const rows = page.getByTestId('masters-row');
	await expect(rows.first()).toBeVisible();
	expect(await rows.first().evaluate((el) => getComputedStyle(el).borderBottomWidth)).toBe('0px');
	const name = rows.first().locator('td').first();
	expect(await name.getAttribute('data-label')).toBeNull();
	await page.goto('/dms');
	await expect(page.getByTestId('dms-row').first()).toBeVisible();
	expect(await page.getByTestId('dms-list').locator('thead th').first().evaluate((el) => getComputedStyle(el.closest('tr')!).borderBottomWidth)).toBe('0px');
	await page.goto('/dms/rules');
	await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
	const cut = await page.getByTestId('tenant-switch').evaluate((el: HTMLSelectElement) => el.getBoundingClientRect().width);
	expect(cut).toBeGreaterThanOrEqual(145);
	await page.goto('/dms/inbox');
	const link = page.getByRole('link', { name: 'Alle Dokumente' });
	await expect(link).toHaveClass(/text-ui-accent-ink/);
});

test('own finding: on a phone the header shows short page names in full next to the tenant', async ({ page, context, request }) => {
	await bootstrapWithDocs(page, context, request);
	await page.setViewportSize(PHONE);
	for (const path of ['/dms', '/dms/inbox', '/dms/masters', '/dms/duplicates', '/settings/appearance']) {
		await page.goto(path);
		await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
		const title = page.getByTestId('header-title');
		expect(await title.evaluate((el) => el.scrollWidth - el.clientWidth), path).toBeLessThanOrEqual(0);
		expect(await page.getByTestId('tenant-switch').evaluate((el) => el.getBoundingClientRect().width), path).toBeGreaterThanOrEqual(145);
	}
	// the shortcut that makes room stays reachable through the menu
	await page.getByTestId('menu-toggle').click();
	await page.getByTestId('drawer-settings').click();
	await expect(page.getByTestId('settings-tab-appearance')).toBeVisible();
});
