import AxeBuilder from '@axe-core/playwright';
import { expect, test, type APIRequestContext, type Page } from '@playwright/test';
import { addVirtualAuthenticator } from '../e2e/virtual-authenticator';
import { MOCK_SETUP_TOKEN } from '../mock/api';

// WP-F4c against the mock backend: document overview (table, filters, sorting), detail with facts, inbox, sidebar. Synthetic data only.
// The clock of the test machine is real, so due dates are far in the past (overdue) or far in the future.

test.beforeEach(async ({ request }) => {
	expect((await request.post('/api/__mock/reset')).status()).toBe(204);
});

async function bootstrap(page: Page, context: Parameters<typeof addVirtualAuthenticator>[0]) {
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
}

async function seed(request: APIRequestContext, data: Record<string, unknown>) {
	expect((await request.post('/api/__mock/dms/seed', { data: { count: 1, ...data } })).status()).toBe(204);
}

/** Four synthetic documents of different kinds (the mock recognises them as the real extractor would report them). */
async function seedMix(request: APIRequestContext) {
	await seed(request, { title: 'Rechnung Alpha', extraction: { kind: 'invoice', amount: '119.00', due_date: '2000-01-15', reference: 'R-ALPHA' }, suggest: true });
	await seed(request, { title: 'Rechnung Beta', extraction: { kind: 'invoice', amount: '450.50', due_date: '2099-01-15', reference: 'R-BETA' } });
	await seed(request, { title: 'Vertrag Gamma', extraction: { kind: 'contract', amount: '30.00' } });
	await seed(request, { title: 'Brief Delta', extraction: { kind: 'letter', kind_certain: false } });
}

async function expectNoSeriousA11y(page: Page, exclude?: string) {
	const builder = new AxeBuilder({ page });
	if (exclude) builder.exclude(exclude);
	const result = await builder.withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
	const bad = result.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
	expect(bad.map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).join(' | ')}`)).toEqual([]);
}

const titles = (page: Page) => page.getByTestId('dms-row').locator('a[data-row-link]').allInnerTexts();

test('overview: kind badges, filters kind + amount + due date, sorting, search (AK-F4c)', async ({ page, context, request }) => {
	await bootstrap(page, context);
	await seedMix(request);
	await page.goto('/dms');
	await expect(page.getByTestId('dms-row')).toHaveCount(4);
	await expect(page.getByTestId('dms-list').locator('th')).toContainText(['Art', 'Titel / Absender', 'Datum', 'Betrag', 'Fällig', 'Referenz', 'Status']);

	// Table cells: kind badge, amount with currency, reference, overdue due date.
	const alpha = page.getByTestId('dms-row').filter({ hasText: 'Rechnung Alpha' });
	await expect(alpha.getByTestId('kind-badge')).toHaveText('Rechnung');
	await expect(alpha.getByTestId('dms-row-amount')).toContainText('119,00');
	await expect(alpha.getByTestId('dms-row-reference')).toHaveText('R-ALPHA');
	await expect(alpha.getByTestId('dms-row-due')).toContainText('überfällig');
	await expect(alpha.getByTestId('dms-row-suggestions')).toContainText('1 Vorschläge offen');
	await expect(page.getByTestId('dms-row').filter({ hasText: 'Brief Delta' }).getByTestId('kind-badge')).toContainText('Brief');
	await expect(page.getByTestId('dms-row').filter({ hasText: 'Brief Delta' }).getByTestId('kind-badge')).toContainText('Art unsicher');
	await expectNoSeriousA11y(page);

	// kind
	await page.getByTestId('dms-filter-kind').selectOption('invoice');
	await expect(page).toHaveURL(/kind=invoice/);
	await expect(page.getByTestId('dms-row')).toHaveCount(2);
	// amount range
	await page.getByTestId('dms-filter-min').fill('200');
	await page.getByTestId('dms-filter-min').blur();
	await expect(page).toHaveURL(/min=200/);
	await expect(page.getByTestId('dms-row')).toHaveCount(1);
	await expect(page.getByTestId('dms-row')).toContainText('Rechnung Beta');
	await page.getByTestId('dms-filter-max').fill('100');
	await page.getByTestId('dms-filter-max').blur();
	await expect(page.getByTestId('dms-empty')).toBeVisible();
	await page.getByTestId('dms-filter-min').fill('abc');
	await page.getByTestId('dms-filter-min').blur();
	await expect(page.getByTestId('dms-amount-invalid')).toBeVisible();
	await page.getByTestId('dms-filter-min').fill('');
	await page.getByTestId('dms-filter-min').blur();
	await expect(page).not.toHaveURL(/min=/);
	await page.getByTestId('dms-filter-max').fill('');
	await page.getByTestId('dms-filter-max').blur();
	await expect(page).not.toHaveURL(/max=/);
	await expect(page.getByTestId('dms-row')).toHaveCount(2);
	// due date
	await page.getByTestId('dms-filter-due').selectOption('overdue');
	await expect(page.getByTestId('dms-row')).toHaveCount(1);
	await expect(page.getByTestId('dms-row')).toContainText('Rechnung Alpha');
	await page.getByTestId('dms-filter-due').selectOption('week');
	await expect(page.getByTestId('dms-empty')).toBeVisible();
	// reload keeps the filters (URL is the state)
	await page.reload();
	await expect(page.getByTestId('dms-filter-due')).toHaveValue('week');
	await page.getByTestId('dms-filter-reset').click();
	await expect(page.getByTestId('dms-row')).toHaveCount(4);

	// sorting by amount via the column header: descending first, then ascending; documents without an amount stay last
	await page.getByTestId('dms-sort-amount').click();
	await expect(page).toHaveURL(/sort=amount/);
	await expect.poll(() => titles(page)).toEqual(['Rechnung Beta', 'Rechnung Alpha', 'Vertrag Gamma', 'Brief Delta']);
	await expect(page.getByRole('columnheader', { name: /Betrag/ })).toHaveAttribute('aria-sort', 'descending');
	await page.getByTestId('dms-sort-amount').click();
	await expect.poll(() => titles(page)).toEqual(['Vertrag Gamma', 'Rechnung Alpha', 'Rechnung Beta', 'Brief Delta']);
	// sorting by due date through the select
	await page.getByTestId('dms-sort').selectOption('due:asc');
	// documents without a due date follow in no fixed order
	await expect.poll(async () => (await titles(page)).slice(0, 2)).toEqual(['Rechnung Alpha', 'Rechnung Beta']);
	await page.getByTestId('dms-filter-reset').click();

	// search (full text route): title match
	await page.getByTestId('dms-search').fill('Gamma');
	await page.getByTestId('dms-search-submit').click();
	await expect(page).toHaveURL(/q=Gamma/);
	await expect(page.getByTestId('dms-row')).toHaveCount(1);
	await expect(page.getByTestId('dms-row')).toContainText('Vertrag Gamma');
	// kind + search runs on the list route and says so
	await page.getByTestId('dms-filter-kind').selectOption('contract');
	await expect(page.getByTestId('dms-list-route-hint')).toBeVisible();
	await expect(page.getByTestId('dms-row')).toHaveCount(1);
});

test('overview: time range presets and "only with open suggestions"', async ({ page, context, request }) => {
	await bootstrap(page, context);
	await seedMix(request);
	await page.goto('/dms');
	await expect(page.getByTestId('dms-row')).toHaveCount(4);

	// The seeded documents have no date: a preset that applies to the document date hides them, "all" brings them back.
	await page.getByTestId('dms-preset-month').click();
	await expect(page).toHaveURL(/from=\d{4}-\d{2}-01/);
	await expect(page.getByTestId('dms-preset-month')).toHaveAttribute('aria-pressed', 'true');
	await expect(page.getByTestId('dms-empty')).toBeVisible();
	await page.getByTestId('dms-preset-month').click();
	await expect(page.getByTestId('dms-row')).toHaveCount(4);
	await page.getByTestId('dms-preset-today').click();
	await expect(page).toHaveURL(/from=(\d{4}-\d{2}-\d{2}).*to=\1/);
	await page.getByTestId('dms-preset-all').click();
	await expect(page.getByTestId('dms-row')).toHaveCount(4);

	await page.getByTestId('dms-filters').locator('summary').click();
	await page.getByTestId('dms-filter-open').check();
	await expect(page).toHaveURL(/open=1/);
	await expect(page.getByTestId('dms-row')).toHaveCount(1);
	await expect(page.getByTestId('dms-row')).toContainText('Rechnung Alpha');
});

test('detail: facts with source and reason, re-run, accept the candidate, English (AK-F4c)', async ({ page, context, request }) => {
	await bootstrap(page, context);
	await seedMix(request);
	await page.goto('/dms');
	await page.getByTestId('dms-row').filter({ hasText: 'Rechnung Alpha' }).getByRole('link').first().click();
	await expect(page.getByTestId('dms-detail-title')).toHaveText('Rechnung Alpha');
	await expect(page.getByTestId('dms-facts')).toBeVisible();
	await expect(page.getByTestId('dms-facts').getByTestId('kind-badge')).toHaveText('Rechnung');
	const amount = page.locator('[data-testid=dms-fact][data-type=amount_gross]');
	await expect(amount.getByTestId('dms-fact-value')).toContainText('119,00');
	await expect(amount).toContainText('90 %');
	await expect(amount).toContainText('Beschriftung "Betrag"');
	await expect(amount.getByTestId('dms-fact-source')).toContainText('Betrag: 119.00');
	await expect(page.locator('[data-testid=dms-fact][data-type=due_date]')).toBeVisible();
	await expectNoSeriousA11y(page);

	await page.getByTestId('dms-extraction-rerun').click();
	await expect(page.getByTestId('dms-fact')).toHaveCount(3);

	// accept the candidate of the recognition (existing suggestion route)
	const suggestion = page.getByTestId('doc-suggestion');
	await expect(suggestion).toHaveCount(1);
	await expect(suggestion).toContainText('Erkennung');
	await suggestion.getByTestId('suggestion-accept').click();
	await expect(page.getByTestId('doc-suggestion')).toHaveCount(0);
	await expect(page.getByTestId('dms-edit-type').locator('option:checked')).toHaveText('Rechnung');

	await page.getByTestId('language-switch').first().selectOption('en');
	await expect(page.getByTestId('dms-facts')).toContainText('Recognised facts');
	await expect(page.locator('[data-testid=dms-fact][data-type=due_date]')).toContainText('Due date');
	await expectNoSeriousA11y(page);
});

test('detail: mail shows the protected HTML part in a sandboxed frame, attachment and mail are linked', async ({ page, context, request }) => {
	await bootstrap(page, context);
	await seed(request, { title: 'Anhang Rechnung', mail: true, extraction: { kind: 'invoice', amount: '10.00' } });
	await page.goto('/dms');
	await page.getByTestId('dms-row').filter({ hasText: 'Anhang Rechnung' }).filter({ hasNotText: '(Mail)' }).getByRole('link').first().click();
	await expect(page.getByTestId('dms-link')).toHaveAttribute('data-role', 'mail');
	await page.getByTestId('dms-link').getByRole('link').click();

	await expect(page.getByTestId('dms-detail-title')).toContainText('(Mail)');
	const frame = page.getByTestId('dms-preview-mail');
	await expect(frame).toHaveAttribute('sandbox', '');
	await expect(frame).toHaveAttribute('src', /role=derivative&disposition=inline/);
	await expect(page.frameLocator('[data-testid=dms-preview-mail]').locator('p')).toContainText('Synthetische Mail');
	// the script in the mail never ran, in neither frame nor page
	expect(await page.evaluate(() => (window as unknown as { __mailxss?: number }).__mailxss)).toBeUndefined();
	const src = await frame.getAttribute('src');
	const response = await page.request.get(src as string);
	expect(response.headers()['content-security-policy']).toBe("default-src 'none'; sandbox");
	expect(response.headers()['x-content-type-options']).toBe('nosniff');
	await expect(page.getByTestId('dms-link')).toHaveAttribute('data-role', 'attachment');
	// the mail content itself is foreign content in a sandboxed frame and not part of the page's own markup
	await expectNoSeriousA11y(page, '[data-testid=dms-preview-mail]');
});

test('inbox: needs attention with direct actions (accept suggestion, due dates), recent documents (AK-F4c)', async ({ page, context, request }) => {
	await bootstrap(page, context);
	await seedMix(request);
	await page.getByTestId('dms-nav-inbox').click();
	await expect(page).toHaveURL(/\/dms\/inbox$/);
	await expect(page.getByRole('heading', { level: 1 })).toHaveText('Eingang');
	await expect(page.getByTestId('inbox-suggestion')).toHaveCount(1);
	await expect(page.getByTestId('inbox-due-item')).toHaveCount(1);
	await expect(page.getByTestId('inbox-due-item').filter({ hasText: 'Rechnung Alpha' })).toContainText('überfällig');
	await expect(page.getByTestId('inbox-recent-item')).toHaveCount(4);
	await expectNoSeriousA11y(page);

	await page.getByTestId('inbox-suggestion').getByTestId('suggestion-accept').click();
	await expect(page.getByTestId('inbox-suggestion')).toHaveCount(0);
	await expect(page.getByTestId('inbox-suggestions')).toHaveCount(0);

	// the accepted type is visible in the table afterwards
	await page.getByTestId('nav-dms').click();
	await expect(page.getByTestId('dms-row').filter({ hasText: 'Rechnung Alpha' })).toContainText('Rechnung');

	await page.getByTestId('language-switch').first().selectOption('en');
	await page.getByTestId('dms-nav-inbox').click();
	await expect(page.getByRole('heading', { level: 1 })).toHaveText('Inbox');
	await expectNoSeriousA11y(page);
});

test('keyboard: arrows move in the table, Enter opens; filter bar is operable by keyboard', async ({ page, context, request }) => {
	await bootstrap(page, context);
	await seedMix(request);
	await page.goto('/dms');
	await expect(page.getByTestId('dms-row')).toHaveCount(4);
	const links = page.locator('a[data-row-link]');
	await expect(page.locator('a[data-row-link][tabindex="0"]')).toHaveCount(1);
	await links.first().focus();
	await page.keyboard.press('ArrowDown');
	await expect(links.nth(1)).toBeFocused();
	await page.keyboard.press('j');
	await expect(links.nth(2)).toBeFocused();
	await page.keyboard.press('End');
	await expect(links.last()).toBeFocused();
	await page.keyboard.press('Home');
	await expect(links.first()).toBeFocused();

	// filter bar: tab through the controls, change the kind with the keyboard, commit an amount with Enter
	await page.keyboard.press('/');
	await expect(page.getByTestId('dms-search')).toBeFocused();
	await page.getByTestId('dms-filter-kind').focus();
	await page.getByTestId('dms-filter-kind').selectOption('invoice');
	await expect(page.getByTestId('dms-row')).toHaveCount(2);
	await page.getByTestId('dms-filter-min').focus();
	await page.keyboard.type('200');
	await page.keyboard.press('Enter');
	await expect(page).toHaveURL(/min=200/);
	await expect(page.getByTestId('dms-row')).toHaveCount(1);
	// sort header is a real button reachable by keyboard
	await page.getByTestId('dms-sort-due').focus();
	await page.keyboard.press('Enter');
	await expect(page).toHaveURL(/sort=due/);
	await expect(page.getByRole('columnheader', { name: /Fällig/ })).toHaveAttribute('aria-sort', 'ascending');

	await page.getByTestId('dms-filter-reset').click();
	await links.nth(1).focus();
	await page.keyboard.press('Enter');
	await expect(page).toHaveURL(/\/dms\/[0-9a-f-]{36}$/);
});

test('sidebar: grouped navigation, collapsible groups remembered, current page marked', async ({ page, context, request }) => {
	await bootstrap(page, context);
	await seedMix(request);
	const sidebar = page.getByTestId('sidebar');
	await expect(sidebar.getByTestId('nav-group-dms.documents')).toHaveText(/Dokumente/);
	await expect(sidebar.getByTestId('nav-group-dms.admin')).toHaveText(/Verwaltung/);
	await expect(sidebar.getByTestId('nav-settings')).toHaveText(/Einstellungen/);
	await expect(sidebar.getByTestId('dms-nav-inbox')).toBeVisible();
	await expect(sidebar.getByTestId('dms-nav-rules')).toBeVisible();

	await sidebar.getByTestId('nav-group-dms.admin').click();
	await expect(sidebar.getByTestId('dms-nav-rules')).toBeHidden();
	await expect(sidebar.getByTestId('nav-group-dms.admin')).toHaveAttribute('aria-expanded', 'false');
	await page.reload();
	await expect(sidebar.getByTestId('dms-nav-rules')).toBeHidden();
	await sidebar.getByTestId('nav-group-dms.admin').click();
	await expect(sidebar.getByTestId('dms-nav-rules')).toBeVisible();

	await sidebar.getByTestId('dms-nav-rules').click();
	await expect(page).toHaveURL(/\/dms\/rules$/);
	await expect(sidebar.getByTestId('dms-nav-rules')).toHaveAttribute('aria-current', 'page');
	await expect(sidebar.getByTestId('nav-dms')).not.toHaveAttribute('aria-current', 'page');

	// settings group lists the settings pages
	await sidebar.getByTestId('nav-settings').click();
	await expect(sidebar.getByTestId('settings-tab-profile')).toBeVisible();
	await expect(sidebar.getByTestId('settings-tab-members')).toBeVisible();

	// keyboard: arrows inside the navigation
	await sidebar.getByTestId('nav-dashboard').focus();
	await page.keyboard.press('ArrowDown');
	await expect(sidebar.getByTestId('nav-group-dms.documents')).toBeFocused();
	await expectNoSeriousA11y(page);
});

test('mobile viewport: no horizontal page scroll, the sidebar is a drawer', async ({ page, context, request }) => {
	await page.setViewportSize({ width: 390, height: 844 });
	await bootstrap(page, context);
	await seedMix(request);
	await seed(request, { title: 'Sehr langer Titel '.repeat(8), extraction: { kind: 'invoice', amount: '1234567.89', due_date: '2000-01-01', reference: 'R-1234567890-ABCDEFGHIJ' }, mail: true });

	const noOverflow = async () => {
		const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
		expect(overflow).toBeLessThanOrEqual(0);
	};
	await page.goto('/dms');
	await expect(page.getByTestId('dms-row').first()).toBeVisible();
	await noOverflow();
	await expectNoSeriousA11y(page);
	await page.goto('/dms/inbox');
	await expect(page.getByTestId('inbox-recent-item').first()).toBeVisible();
	await noOverflow();
	await page.goto('/dms');
	await page.getByTestId('dms-row').first().getByRole('link').first().click();
	await expect(page.getByTestId('dms-facts')).toBeVisible();
	await noOverflow();

	// drawer: closed at first, opens from the top bar, closes after navigating
	await page.goto('/dms');
	await expect(page.getByTestId('sidebar')).toBeHidden();
	await page.getByTestId('menu-toggle').click();
	await expect(page.getByTestId('dms-nav-inbox')).toBeVisible();
	await page.getByTestId('dms-nav-inbox').click();
	await expect(page).toHaveURL(/\/dms\/inbox$/);
	await expect(page.getByTestId('dms-nav-inbox')).toBeHidden();
	await noOverflow();
});
