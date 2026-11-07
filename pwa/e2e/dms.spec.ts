import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { renderScanPdf } from './scan-pdf';
import { addVirtualAuthenticator } from './virtual-authenticator';

// WP-F4b: AK-F4-1 against the REAL backend with a REAL OCR worker (`App worker --kinds dms.ocr`):
// bootstrap -> invitation -> passkey -> upload of a synthetic scan PDF -> processing finished -> hit in search ->
// preview/download -> trash. Run with `npm run test:e2e:dms` (needs a fresh database, see docs/FRONTEND.md section 11).
const setupToken = process.env.E2E_SETUP_TOKEN;

test.skip(!setupToken || !process.env.E2E_DMS, 'E2E_SETUP_TOKEN/E2E_DMS not set: needs a fresh backend with SETUP_TOKEN and a running OCR worker');

async function expectNoSeriousA11y(page: Page) {
	const result = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
	const bad = result.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
	expect(bad.map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).join(' | ')}`)).toEqual([]);
}

test('AK-F4-1 real: bootstrap, invitation, passkey, scan upload, OCR done, search hit, preview, download, trash', async ({ browser }) => {
	test.setTimeout(240_000);

	// 1. Operator bootstrap, enable the DMS module, create an invitation for an accountant (may trash documents).
	const ownerContext = await browser.newContext();
	const owner = await ownerContext.newPage();
	await addVirtualAuthenticator(ownerContext, owner);
	await owner.goto('/setup');
	await owner.getByLabel('Setup-Token').fill(setupToken!);
	await owner.getByLabel('Kennung').fill('owner');
	await owner.getByLabel('Anzeigename').fill('Owner Test');
	await owner.getByRole('button', { name: 'Passkey anlegen und starten' }).click();
	await expect(owner).toHaveURL(/\/dashboard$/);
	await owner.goto('/settings/modules');
	await owner.getByTestId('module-toggle-dms').click();
	await expect(owner.getByTestId('nav-dms')).toBeVisible();
	await owner.goto('/settings/members');
	await owner.locator('#invite-role').selectOption('accountant');
	await owner.getByTestId('invite-create').click();
	const link = (await owner.getByTestId('invite-link').innerText()).trim();
	const invitePath = link.startsWith('http') ? new URL(link).pathname : link;

	// 2. Invited accountant: invitation -> passkey -> dashboard.
	const context = await browser.newContext();
	const page = await context.newPage();
	await addVirtualAuthenticator(context, page);
	await page.goto(invitePath);
	await page.getByLabel('Kennung').fill('buchhaltung');
	await page.getByLabel('Anzeigename').fill('Buchhaltung Test');
	await page.getByRole('button', { name: 'Passkey anlegen' }).click();
	await expect(page).toHaveURL(/\/dashboard$/);
	await page.getByTestId('nav-dms').click();
	await expect(page.getByTestId('dms-search')).toBeVisible();

	// Browsing an empty archive works without a search term.
	await expect(page.getByTestId('dms-empty')).toBeVisible();

	// 3. Upload a synthetic scan (image only, no text layer).
	const unique = 'Wasserzaehler';
	const pdf = await renderScanPdf(page, [`Quartalsabrechnung ${unique}`, 'Rechnungsnummer 2026-4711', 'Herbstmesse Bremen']);
	await page.getByTestId('dms-file-input').setInputFiles({ name: 'scan.pdf', mimeType: 'application/pdf', buffer: pdf });
	const item = page.getByTestId('dms-upload-item');
	await expect(item).toHaveAttribute('data-state', /processing|done/);
	// 4. The worker runs OCR (ocrmypdf + Tesseract); the queue polls GET .../processing until done.
	await expect(item).toHaveAttribute('data-state', 'done', { timeout: 180_000 });

	// 5. Hit in the search with a highlighted snippet.
	await page.getByTestId('dms-search').fill(unique);
	await page.getByTestId('dms-search-submit').click();
	await expect(page.getByTestId('dms-row')).toHaveCount(1, { timeout: 30_000 });
	await expect(page.getByTestId('dms-snippet').locator('mark').first()).toContainText(/wasserzaehler/i);
	await expectNoSeriousA11y(page);

	// 6. Empty search term = browsing: the document is listed, without snippet.
	await page.getByTestId('dms-search').fill('');
	await page.getByTestId('dms-search-submit').click();
	await expect(page.getByTestId('dms-row')).toHaveCount(1);
	await expect(page.getByTestId('dms-snippet')).toHaveCount(0);
	await expect(page.getByTestId('dms-filter-from')).toBeEnabled();

	// 7. Detail: processing is over, archive version previewed from a blob URL, original can be downloaded.
	await page.getByTestId('dms-row').first().getByRole('link').first().click();
	await expect(page.getByTestId('dms-detail-title')).toBeVisible();
	await expect(page.getByTestId('dms-processing-status')).toHaveCount(0);
	await expect(page.getByTestId('dms-quarantine-banner')).toHaveCount(0);
	await expect(page.getByTestId('dms-preview-pdf')).toHaveAttribute('src', /^blob:/);
	const href = await page.getByTestId('dms-download').getAttribute('href');
	const original = await context.request.get(href!);
	expect(original.status()).toBe(200);
	expect(original.headers()['content-type']).toContain('application/pdf');
	expect((await original.body()).equals(pdf)).toBe(true);
	const archive = await context.request.get(href!.replace('role=original', 'role=archive').replace('attachment', 'inline'));
	expect(archive.status()).toBe(200);
	expect((await archive.body()).subarray(0, 5).toString('latin1')).toBe('%PDF-');
	await expectNoSeriousA11y(page);

	// 8. Trash with a reason: the document leaves the search, shows up in the trash.
	await page.getByTestId('dms-trash-reason').fill('E2E Aufräumen');
	await page.getByTestId('dms-trash').click();
	await expect(page.getByTestId('dms-trashed-banner')).toContainText('E2E Aufräumen');
	await page.getByTestId('dms-back').click();
	await expect(page.getByTestId('dms-empty')).toBeVisible();
	await page.getByTestId('dms-search').fill(unique);
	await page.getByTestId('dms-search-submit').click();
	await expect(page).toHaveURL(/q=Wasserzaehler/);
	await expect(page.getByTestId('dms-empty')).toBeVisible();
	await page.getByTestId('dms-search').fill('');
	await page.getByTestId('dms-search-submit').click();
	await expect(page).not.toHaveURL(/q=/);
	if (!(await page.getByTestId('dms-trash-toggle').isVisible())) await page.getByTestId('dms-filters').locator('summary').click();
	await page.getByTestId('dms-trash-toggle').check();
	await expect(page.getByTestId('dms-row')).toHaveCount(1);

	await ownerContext.close();
	await context.close();
});
