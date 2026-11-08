import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { execFile } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { renderScanPdf } from './scan-pdf';
import { addVirtualAuthenticator } from './virtual-authenticator';

// WP-F4b: AK-F4-1 against the REAL backend with a REAL OCR worker (`App worker --kinds dms.ocr,dms.verify,dms.export`):
// bootstrap -> invitation -> passkey -> upload of a synthetic scan PDF -> processing finished -> hit in search ->
// preview/download -> trash. Run with `npm run test:e2e:dms` (needs a fresh database, see docs/FRONTEND.md section 11).
// WP-F5 extends the path: master data (document type) -> rule with dry run -> upload -> suggestion appears in the review
// queue with its reason -> accepted by keyboard -> the document has the type; then integrity check, export, trash page.
// WP-F5b adds: sources UI (mail source with a refused connection), API token -> curl upload (share API) -> document appears
// -> revoked token refused. The backend needs SECRET_KEY (>= 16 characters) for the mail source password.
const execFileAsync = promisify(execFile);
const setupToken = process.env.E2E_SETUP_TOKEN;

test.skip(!setupToken || !process.env.E2E_DMS, 'E2E_SETUP_TOKEN/E2E_DMS not set: needs a fresh backend with SETUP_TOKEN and a running OCR worker');

async function expectNoSeriousA11y(page: Page) {
	const result = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
	const bad = result.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
	expect(bad.map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).join(' | ')}`)).toEqual([]);
}

test('AK-F4-1 real: bootstrap, invitation, passkey, scan upload, OCR done, search hit, preview, download, trash', async ({ browser }) => {
	test.setTimeout(420_000);

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

	// 2b. WP-F5: a document type and a rule (mode suggest) with a dry run against the still empty archive.
	await page.getByTestId('dms-nav-masters').click();
	await page.getByTestId('masters-new').click();
	await page.getByTestId('masters-f-name').fill('Rechnung');
	await page.getByTestId('masters-save').click();
	await expect(page.getByTestId('masters-row').filter({ hasText: 'Rechnung' })).toHaveCount(1);
	await page.getByTestId('dms-nav-rules').click();
	await page.getByTestId('rule-new').click();
	await page.getByTestId('rule-name').fill('Wasserzaehler-Regel');
	await page.getByTestId('rule-cond-value').fill('wasserzaehler');
	await page.getByTestId('rule-act-type').selectOption({ label: 'Rechnung' });
	await page.getByTestId('rule-preview-run').click();
	await expect(page.getByTestId('rule-preview-summary')).toContainText('0 Treffer');
	await expectNoSeriousA11y(page);
	await page.getByTestId('rule-save').click();
	await expect(page.getByTestId('rule-saved')).toBeVisible();
	await expect(page.getByTestId('rule-row')).toHaveCount(1);
	await page.getByTestId('dms-nav-documents').click();
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

	// 4b. WP-F5: the classification step created a suggestion from the rule; it is accepted with the keyboard.
	await page.getByTestId('dms-nav-review').click();
	await expect(page.getByTestId('review-row')).toHaveCount(1, { timeout: 30_000 });
	await expect(page.getByTestId('suggestion-reason')).toContainText('Wasserzaehler-Regel');
	await expect(page.getByTestId('suggestion-value')).toHaveText('Rechnung');
	await expectNoSeriousA11y(page);
	await page.getByTestId('suggestion-document').focus();
	await page.keyboard.press('a');
	await expect(page.getByTestId('review-empty')).toBeVisible();
	await page.getByTestId('dms-nav-documents').click();
	await expect(page.getByTestId('dms-search')).toBeVisible();

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
	await expect(page.getByTestId('dms-edit-type').locator('option:checked')).toHaveText('Rechnung');
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

	// 7b. WP-F5: integrity check (worker kind dms.verify) and export (dms.export) with download.
	await page.getByTestId('dms-nav-integrity').click();
	await page.getByTestId('integrity-start').click();
	await expect(page.getByTestId('integrity-run').first()).toHaveAttribute('data-state', 'passed', { timeout: 120_000 });
	await expect(page.getByTestId('integrity-head')).toHaveText(/^[0-9a-f]{64}$/);
	await expectNoSeriousA11y(page);
	await page.getByTestId('dms-nav-exports').click();
	await page.getByTestId('export-start').click();
	await expect(page.getByTestId('export-row').first()).toHaveAttribute('data-state', 'done', { timeout: 120_000 });
	await expect(page.getByTestId('export-documents')).toHaveText('1');
	const zip = await context.request.get((await page.getByTestId('export-download').getAttribute('href'))!);
	expect(zip.status()).toBe(200);
	expect((await zip.body()).subarray(0, 2).toString('latin1')).toBe('PK');
	await page.getByTestId('dms-nav-documents').click();
	await page.getByTestId('dms-row').first().getByRole('link').first().click();
	await expect(page.getByTestId('dms-detail-title')).toBeVisible();

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

	// 9. WP-F5: the trash page shows the retention period and why purging is not possible (period running, owner only).
	await page.getByTestId('dms-nav-trash').click();
	await expect(page.getByTestId('trash-row')).toHaveCount(1);
	await expect(page.getByTestId('trash-purge-state')).toContainText('Aufbewahrungsfrist ist noch nicht abgelaufen');
	await expect(page.getByTestId('trash-purge')).toHaveCount(0);
	await expect(page.getByTestId('trash-owner-only')).toBeVisible();
	await expectNoSeriousA11y(page);

	// 10. WP-F5b: sources UI against the real backend (SECRET_KEY set): a mail source whose server refuses the connection
	// reports `imap_connect_failed` as a text, the password is never shown; disable, delete.
	await page.getByTestId('dms-nav-sources').click();
	await page.getByTestId('source-new-mail').click();
	await page.getByTestId('source-name').fill('E2E Postfach');
	await page.getByTestId('source-host').fill('127.0.0.1');
	await page.getByTestId('source-port').fill('1');
	await page.getByTestId('source-username').fill('e2e@example.org');
	await page.getByTestId('source-password').fill('E2E-Not-A-Real-Password');
	await page.getByTestId('source-save').click();
	await expect(page.getByTestId('source-saved')).toBeVisible();
	const sourceRow = page.getByTestId('source-row').filter({ hasText: 'E2E Postfach' });
	await expect(page.locator('body')).not.toContainText('E2E-Not-A-Real-Password');
	await sourceRow.getByTestId('source-test').click();
	await expect(sourceRow.getByTestId('source-test-result')).toHaveAttribute('data-code', 'imap_connect_failed', { timeout: 30_000 });
	await sourceRow.getByTestId('source-edit').click();
	await expect(page.getByTestId('source-password')).toHaveValue('');
	await page.getByTestId('source-cancel').click();
	await sourceRow.getByTestId('source-toggle').click();
	await expect(sourceRow).toHaveAttribute('data-enabled', 'false');
	await expectNoSeriousA11y(page);
	await sourceRow.getByTestId('source-delete').click();
	await page.getByTestId('source-delete-dialog-confirm').click();
	await expect(page.getByTestId('sources-empty')).toBeVisible();

	// 11. WP-F5b: API token -> upload with curl -> document appears -> revoked token is refused.
	await page.getByTestId('dms-nav-tokens').click();
	await page.getByTestId('token-name').fill('E2E curl');
	await page.getByTestId('token-create').click();
	const token = ((await page.getByTestId('token-plain').textContent()) ?? '').trim();
	expect(token).toMatch(/^lhp_[A-Za-z0-9_-]{43}$/);
	await page.getByTestId('token-dismiss').click();
	await page.getByTestId('dms-nav-scanner').click();
	const endpointPath = new URL((await page.getByTestId('scanner-endpoint').innerText()).trim()).pathname;
	expect(endpointPath).toMatch(/^\/api\/v1\/tenants\/[0-9a-f-]{36}\/dms\/share$/i);
	const shareUrl = `http://localhost:${process.env.E2E_PORT ?? 5173}${endpointPath}?filename=curl-scan.pdf`;
	const curlUnique = 'Heizkostenabrechnung';
	const curlPdf = await renderScanPdf(page, [`Jahresabrechnung ${curlUnique}`, 'Eingang per curl und API-Token']);
	const dir = mkdtempSync(join(tmpdir(), 'labhub-f5b-'));
	const file = join(dir, 'curl-scan.pdf');
	writeFileSync(file, curlPdf);
	const upload = async (bearer: string) => {
		const { stdout } = await execFileAsync('curl', ['-sS', '-X', 'POST', shareUrl, '-H', `Authorization: Bearer ${bearer}`, '-H', 'Content-Type: application/octet-stream', '--data-binary', `@${file}`, '-w', '\n%{http_code}']);
		const cut = stdout.lastIndexOf('\n');
		return { status: Number(stdout.slice(cut + 1)), body: stdout.slice(0, cut) };
	};
	try {
		const first = await upload(token);
		expect(first.status).toBe(201);
		const created = JSON.parse(first.body) as { id: string };
		// The same file again is answered with the first document (no second document).
		const again = await upload(token);
		expect(again.status).toBe(201);
		expect((JSON.parse(again.body) as { id: string }).id).toBe(created.id);

		await page.getByTestId('dms-nav-documents').click();
		await expect(page.getByTestId('dms-row')).toHaveCount(1, { timeout: 30_000 });
		await page.getByTestId('dms-row').first().getByRole('link').first().click();
		await expect(page).toHaveURL(new RegExp(created.id));
		await expect(page.getByTestId('dms-detail-title')).toBeVisible();
		await expect(page.getByTestId('dms-processing-status')).toHaveCount(0, { timeout: 180_000 });
		await page.getByTestId('dms-back').click();
		await page.getByTestId('dms-search').fill(curlUnique);
		await page.getByTestId('dms-search-submit').click();
		await expect(page.getByTestId('dms-row')).toHaveCount(1, { timeout: 30_000 });
		await expect(page.getByTestId('dms-snippet').locator('mark').first()).toContainText(/heizkostenabrechnung/i);

		// Revoke in the UI: the same token is refused at once.
		await page.getByTestId('dms-nav-tokens').click();
		await page.getByTestId('token-revoke').click();
		await page.getByTestId('token-revoke-dialog-confirm').click();
		await expect(page.getByTestId('token-state')).toHaveText('Widerrufen');
		expect((await upload(token)).status).toBe(401);
	} finally {
		rmSync(dir, { recursive: true, force: true });
	}

	await ownerContext.close();
	await context.close();
});
