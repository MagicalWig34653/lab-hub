import AxeBuilder from '@axe-core/playwright';
import { expect, test, type APIRequestContext, type Page } from '@playwright/test';
import { addVirtualAuthenticator } from '../e2e/virtual-authenticator';
import { MOCK_SETUP_TOKEN } from '../mock/api';

// WP-F4d against the mock backend: totals per currency, source column and filter, server-side "open suggestions", dashboard counters
// from `GET dms/stats`, facts of the D8 kinds, search hits with kind and amount. Synthetic data only.

test.beforeEach(async ({ request }) => {
	expect((await request.post('/api/__mock/reset')).status()).toBe(204);
});

async function bootstrap(page: Page, context: Parameters<typeof addVirtualAuthenticator>[0]) {
	await addVirtualAuthenticator(context, page);
	await page.setViewportSize({ width: 1400, height: 900 });
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

async function expectNoSeriousA11y(page: Page) {
	const result = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
	const bad = result.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
	expect(bad.map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).join(' | ')}`)).toEqual([]);
}

async function seedMix(request: APIRequestContext) {
	await seed(request, { title: 'Rechnung Alpha', source: 'mail', extraction: { kind: 'invoice', amount: '119.00', due_date: '2000-01-15', reference: 'R-ALPHA' }, suggestions: 2 });
	await seed(request, { title: 'Rechnung Beta', source: 'upload', extraction: { kind: 'invoice', amount: '450.50', due_date: '2099-01-15', reference: 'R-BETA' } });
	await seed(request, { title: 'Rechnung Dollar', source: 'share', extraction: { kind: 'invoice', amount: '10.00', currency: 'USD' } });
	await seed(request, { title: 'Vertrag Gamma', source: 'folder', extraction: { kind: 'contract', amount: '30.00', due_date: '2000-02-01' } });
	await seed(request, { title: 'Brief Delta', extraction: { kind: 'letter', kind_certain: false } });
}

test('totals per currency over the whole filtered set, source column and filter (AK-F4d)', async ({ page, context, request }) => {
	await bootstrap(page, context);
	await seedMix(request);
	await page.goto('/dms');
	await expect(page.getByTestId('dms-row')).toHaveCount(5);

	// two currencies are never mixed: EUR 119,00 + 450,50 + 30,00 and USD 10,00
	const totals = page.getByTestId('dms-totals');
	await expect(totals).toBeVisible();
	await expect(page.locator('[data-testid=dms-total][data-currency=EUR]')).toContainText('599,50');
	await expect(page.locator('[data-testid=dms-total][data-currency=EUR]')).toContainText('3 Dokumente');
	await expect(page.locator('[data-testid=dms-total][data-currency=USD]')).toContainText('10,00');
	await expect(totals).toContainText('nicht nur für die geladenen Zeilen');
	await expectNoSeriousA11y(page);

	// the sum follows the filters
	await page.getByTestId('dms-filter-kind').selectOption('invoice');
	await expect(page.getByTestId('dms-row')).toHaveCount(3);
	await expect(page.locator('[data-testid=dms-total][data-currency=EUR]')).toContainText('569,50');
	await page.getByTestId('dms-filters').locator('summary').click();
	await page.getByTestId('dms-filter-cur').fill('USD');
	await page.getByTestId('dms-filter-cur').blur();
	await expect(page.getByTestId('dms-row')).toHaveCount(1);
	await expect(page.getByTestId('dms-total')).toHaveCount(1);
	await page.getByTestId('dms-filter-reset').click();
	await expect(page.getByTestId('dms-row')).toHaveCount(5);

	// source column and filter
	await expect(page.getByTestId('dms-list').locator('th')).toContainText(['Art', 'Titel / Absender', 'Datum', 'Betrag', 'Fällig', 'Referenz', 'Quelle', 'Status']);
	await expect(page.getByTestId('dms-row').filter({ hasText: 'Rechnung Alpha' }).getByTestId('dms-row-source')).toHaveText('E-Mail');
	await expect(page.getByTestId('dms-row').filter({ hasText: 'Rechnung Dollar' }).getByTestId('dms-row-source')).toHaveText('Scanner / Teilen');
	await page.getByTestId('dms-filters').locator('summary').click();
	await page.getByTestId('dms-filter-source').selectOption('mail');
	await expect(page).toHaveURL(/source=mail/);
	await expect(page.getByTestId('dms-row')).toHaveCount(1);
	await expect(page.getByTestId('dms-row')).toContainText('Rechnung Alpha');
	await expect(page.locator('[data-testid=dms-total][data-currency=EUR]')).toContainText('119,00');
	await page.reload();
	await expect(page.getByTestId('dms-filter-source')).toHaveValue('mail');
	await expect(page.getByTestId('dms-row')).toHaveCount(1);
	await page.getByTestId('dms-filter-reset').click();

	// a search term has no sum (full-text hits cannot be summed on the server) and says so; hits carry kind and amount
	await page.getByTestId('dms-search').fill('Gamma');
	await page.getByTestId('dms-search-submit').click();
	await expect(page.getByTestId('dms-row')).toHaveCount(1);
	await expect(page.getByTestId('dms-totals')).toHaveCount(0);
	await expect(page.getByTestId('dms-totals-hint')).toBeVisible();
	const hit = page.getByTestId('dms-row').filter({ hasText: 'Vertrag Gamma' });
	await expect(hit.getByTestId('kind-badge')).toHaveText('Vertrag');
	await expect(hit.getByTestId('dms-row-amount')).toContainText('30,00');
	await expect(hit.getByTestId('dms-row-source')).toHaveText('Konsumordner');

	// extraction filters and sorting work together with the search term (same route)
	await page.getByTestId('dms-search').fill('Rechnung');
	await page.getByTestId('dms-search-submit').click();
	await expect(page.getByTestId('dms-row')).toHaveCount(3);
	await page.getByTestId('dms-sort').selectOption('amount:desc');
	await expect.poll(() => page.getByTestId('dms-row').locator('a[data-row-link]').allInnerTexts()).toEqual(['Rechnung Beta', 'Rechnung Alpha', 'Rechnung Dollar']);
	await page.getByTestId('dms-filter-min').fill('100');
	await page.getByTestId('dms-filter-min').blur();
	await expect(page.getByTestId('dms-row')).toHaveCount(2);
	await expect(page.getByTestId('dms-list-route-hint')).toHaveCount(0);

	// English
	await page.getByTestId('dms-filter-reset').click();
	await page.getByTestId('language-switch').first().selectOption('en');
	await expect(page.getByTestId('dms-totals')).toContainText('Total of the filtered documents');
	await expect(page.locator('[data-testid=dms-total][data-currency=EUR]')).toContainText('3 documents');
	await expect(page.getByTestId('dms-list').locator('th')).toContainText(['Source']);
	await expectNoSeriousA11y(page);
});

test('"only with open suggestions" is a server filter and not capped (AK-F4d)', async ({ page, context, request }) => {
	await bootstrap(page, context);
	await seedMix(request);
	await page.goto('/dms');
	await expect(page.getByTestId('dms-row')).toHaveCount(5);
	await expect(page.getByTestId('dms-row').filter({ hasText: 'Rechnung Alpha' }).getByTestId('dms-row-suggestions')).toContainText('2 Vorschläge offen');
	await page.getByTestId('dms-filters').locator('summary').click();
	await page.getByTestId('dms-filter-open').check();
	await expect(page).toHaveURL(/open=1/);
	await expect(page.getByTestId('dms-row')).toHaveCount(1);
	await expect(page.getByTestId('dms-row')).toContainText('Rechnung Alpha');
	await page.reload();
	await expect(page.getByTestId('dms-filter-open')).toBeChecked();
	await expect(page.getByTestId('dms-row')).toHaveCount(1);
});

test('dashboard counters come from the stats route (AK-F4d)', async ({ page, context, request }) => {
	await bootstrap(page, context);
	await seedMix(request);
	await seed(request, { title: 'Alt', created_days_ago: 30, extraction: { kind: 'invoice', amount: '1.00', due_date: '2000-03-01' } });
	await page.goto('/dashboard');
	await expect(page.getByTestId('dms-processing-card')).toBeVisible();
	// overdue: Alpha and Alt (the contract is not counted); suggestions count documents; new in 7 days: five of six
	await expect(page.getByTestId('dms-card-overdue')).toHaveText('2');
	await expect(page.getByTestId('dms-card-suggestions')).toHaveText('1');
	await expect(page.getByTestId('dms-card-new')).toHaveText('5');
	await expect(page.getByTestId('dms-card-failed')).toHaveText('0');
	await expect(page.getByTestId('dms-card-processing')).toHaveText('0');
	await expect(page.getByTestId('dms-card-overdue-link')).toHaveAttribute('href', '/dms?due=overdue');
	await expectNoSeriousA11y(page);
	await page.getByTestId('dms-card-overdue-link').click();
	await expect(page).toHaveURL(/\/dms\?due=overdue/);
	// the list filter (unlike the counter) also finds the contract end in the past: Alpha, Gamma, Alt
	await expect(page.getByTestId('dms-row')).toHaveCount(3);
});

test('detail: facts of contract, insurance, authority, bank statement and receipt in readable form (AK-F4d)', async ({ page, context, request }) => {
	await bootstrap(page, context);
	await seed(request, {
		title: 'Vertrag Fakten',
		extraction: {
			kind: 'contract',
			amount: '29.90',
			facts: [
				{ type: 'counterparty', value: 'Muster Strom GmbH' },
				{ type: 'term', value: 'P1Y' },
				{ type: 'notice_period', value: 'P3M' },
				{ type: 'auto_renewal', value: 'true' },
				{ type: 'payment_interval', value: 'quarterly' },
				{ type: 'recurring_amount', value: '29.90', currency: 'EUR' },
				{ type: 'period_end', value: '2027-03-31' }
			]
		}
	});
	await seed(request, {
		title: 'Bescheid Fakten',
		extraction: {
			kind: 'tax_notice',
			facts: [
				{ type: 'authority', value: 'Finanzamt Beispielstadt' },
				{ type: 'notice_type', value: 'tax_assessment' },
				{ type: 'settlement_amount', value: '-120.50', currency: 'EUR' },
				{ type: 'objection_deadline', value: '2027-02-01' }
			]
		}
	});
	await seed(request, {
		title: 'Konto Fakten',
		extraction: { kind: 'bank_statement', facts: [{ type: 'iban', value: 'DE89370400440532013000' }, { type: 'balance_closing', value: '-15.00', currency: 'EUR' }] }
	});
	await seed(request, { title: 'Bon Fakten', extraction: { kind: 'receipt', amount: '8.40', facts: [{ type: 'payment_method', value: 'debit_card' }, { type: 'amount_tax_19', value: '1.34', currency: 'EUR' }] } });
	await seed(request, {
		title: 'Police Fakten',
		extraction: { kind: 'insurance', facts: [{ type: 'insurer', value: 'Beispiel Versicherung AG' }, { type: 'premium', value: '12.00', currency: 'EUR' }, { type: 'policy_number', value: 'P-1234' }] }
	});

	const open = async (title: string) => {
		await page.goto('/dms');
		await page.getByTestId('dms-row').filter({ hasText: title }).getByRole('link').first().click();
		await expect(page.getByTestId('dms-facts')).toBeVisible();
	};
	const fact = (type: string) => page.locator(`[data-testid=dms-fact][data-type=${type}]`);

	await open('Vertrag Fakten');
	await expect(page.getByTestId('dms-facts').getByTestId('kind-badge')).toHaveText('Vertrag');
	await expect(fact('counterparty')).toContainText('Vertragspartner');
	await expect(fact('term').getByTestId('dms-fact-value')).toHaveText('1 Jahr');
	await expect(fact('notice_period')).toContainText('Kündigungsfrist');
	await expect(fact('notice_period').getByTestId('dms-fact-value')).toHaveText('3 Monate');
	await expect(fact('auto_renewal').getByTestId('dms-fact-value')).toHaveText('Ja');
	await expect(fact('payment_interval').getByTestId('dms-fact-value')).toHaveText('vierteljährlich');
	await expect(fact('recurring_amount').getByTestId('dms-fact-value')).toContainText('29,90');
	await expect(fact('period_end').getByTestId('dms-fact-value')).toHaveText('31.03.2027');
	await expectNoSeriousA11y(page);

	await open('Bescheid Fakten');
	await expect(fact('notice_type').getByTestId('dms-fact-value')).toHaveText('Steuerbescheid');
	await expect(fact('settlement_amount')).toContainText('Zahlung / Erstattung');
	await expect(fact('settlement_amount').getByTestId('dms-fact-value')).toContainText('120,50');
	await expect(fact('settlement_amount').getByTestId('dms-fact-value')).toHaveText(/^[-−]/);
	await expect(fact('objection_deadline').getByTestId('dms-fact-value')).toHaveText('01.02.2027');

	await open('Konto Fakten');
	await expect(fact('iban').getByTestId('dms-fact-value')).toHaveText('DE89 3704 0044 0532 0130 00');
	await expect(fact('balance_closing')).toContainText('Endsaldo');

	await open('Bon Fakten');
	await expect(fact('payment_method').getByTestId('dms-fact-value')).toHaveText('Girocard');
	await expect(fact('amount_tax_19')).toContainText('Steuer 19 %');

	await open('Police Fakten');
	await expect(fact('insurer').getByTestId('dms-fact-value')).toHaveText('Beispiel Versicherung AG');
	await expect(fact('premium')).toContainText('Beitrag');

	await page.getByTestId('language-switch').first().selectOption('en');
	await expect(fact('premium')).toContainText('Premium');
	await expectNoSeriousA11y(page);
});
