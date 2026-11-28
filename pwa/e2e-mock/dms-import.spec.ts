import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { addVirtualAuthenticator } from '../e2e/virtual-authenticator';
import { MOCK_SETUP_TOKEN } from '../mock/api';

// WP-PA2 against the mock backend (mock/dms-import.ts): source, dry run, progress, cancel, report, token privacy, notes,
// and the orphan sweep of the integrity report (WP-D5b). All data is synthetic.

const TOKEN = 'synthetic-token-4c1f9a2e77';
const ADDRESS = 'https://paperless.example.org';

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
	await expect(page.getByTestId('nav-dms')).toBeVisible();
	await page.getByTestId('nav-dms').click();
	await expect(page.getByTestId('dms-search')).toBeVisible();
}

async function openImport(page: Page) {
	await page.getByTestId('dms-nav-imports').click();
	await expect(page.getByTestId('import-title')).toBeVisible();
}

async function expectNoSeriousA11y(page: Page) {
	const result = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
	const bad = result.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
	expect(bad.map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).join(' | ')}`)).toEqual([]);
}

/** Everything the browser keeps for this origin, as one string. */
const stored = (page: Page) =>
	page.evaluate(async () => {
		const parts: string[] = [JSON.stringify({ ...localStorage }), JSON.stringify({ ...sessionStorage }), document.cookie, location.href];
		parts.push(JSON.stringify(history.state ?? null));
		for (const info of await indexedDB.databases()) parts.push(info.name ?? '');
		for (const key of await caches.keys()) {
			for (const request of await (await caches.open(key)).keys()) parts.push(request.url);
		}
		parts.push(document.documentElement.outerHTML);
		for (const input of document.querySelectorAll('input, textarea')) parts.push((input as HTMLInputElement).value);
		return parts.join('\n');
	});

test('AK-PA2-1 REST source: dry run with progress and report; the token is sent once and kept nowhere', async ({ page, context }) => {
	const logs: string[] = [];
	page.on('console', (m) => logs.push(m.text()));
	const carrying: string[] = [];
	page.on('request', (r) => {
		if (r.url().includes(TOKEN) || (r.postData() ?? '').includes(TOKEN) || Object.values(r.headers()).join(' ').includes(TOKEN)) carrying.push(`${r.method()} ${new URL(r.url()).pathname}`);
	});
	await bootstrap(page, context);
	await openImport(page);
	await expect(page.getByTestId('import-empty')).toBeVisible();

	const token = page.getByTestId('import-token');
	await expect(token).toHaveAttribute('type', 'password');
	await expect(token).toHaveAttribute('autocomplete', 'off');
	await expect(token).not.toHaveAttribute('name', /.*/);
	// the dry run is preselected: nothing is written unless chosen
	await expect(page.getByTestId('import-mode-dry_run')).toBeChecked();
	await expectNoSeriousA11y(page);

	await page.getByTestId('import-base-url').fill(ADDRESS);
	await token.fill(TOKEN);
	await page.getByTestId('import-start').click();
	await expect(token).toHaveValue('');

	const row = page.getByTestId('import-run').first();
	await expect(row).toHaveAttribute('data-state', /queued|running/);
	const bar = row.getByRole('progressbar');
	await expect(bar).toBeVisible();
	await expect(row.getByTestId('import-progress')).toContainText(/[1-9]\d* von 12 Dokumenten/);
	await expect(row).toHaveAttribute('data-state', 'done', { timeout: 15_000 });

	const report = page.getByTestId('import-report');
	await expect(report).toHaveAttribute('data-state', 'done');
	await expect(report.getByTestId('import-dry-note')).toContainText('nichts geschrieben');
	await expect(report.getByTestId('import-count-documents_seen')).toHaveText('12');
	await expect(report.getByTestId('import-count-documents_would_import')).toHaveText('11');
	const findings = report.getByTestId('import-finding');
	await expect(findings).toHaveCount(2);
	await expect(findings.first()).toContainText('Prüfsumme weicht ab');
	await findings.first().locator('summary').click();
	await expect(findings.first()).toContainText('Dokument 7');
	await expect(report.getByTestId('import-rights')).toContainText('nicht übernommen');
	await expect(report.getByTestId('import-visibility')).toContainText('Token');
	await expect(report.getByTestId('import-asn')).toContainText('4711');
	await expectNoSeriousA11y(page);

	const download = page.waitForEvent('download');
	await report.getByTestId('import-download').click();
	expect((await download).suggestedFilename()).toMatch(/^paperless-import-report-[0-9a-f]{8}\.json$/);

	// once in the request that creates the run, never again, nowhere in the browser
	expect(carrying).toEqual([expect.stringMatching(/^POST \/api\/v1\/tenants\/[0-9a-f-]+\/dms\/imports$/)]);
	expect(await stored(page)).not.toContain(TOKEN);
	expect(logs.join('\n')).not.toContain(TOKEN);
	await page.reload();
	await expect(page.getByTestId('import-run')).toHaveCount(1);
	await expect(page.getByTestId('import-token')).toHaveValue('');
	expect(await stored(page)).not.toContain(TOKEN);
});

test('AK-PA2-1 cancel: a running import stops, keeps what it did and reports it', async ({ page, context }) => {
	await bootstrap(page, context);
	await openImport(page);
	await page.getByTestId('import-base-url').fill(`${ADDRESS}/slow`);
	await page.getByTestId('import-token').fill(TOKEN);
	await page.getByTestId('import-mode-import').check();
	await expect(page.getByTestId('import-writes-hint')).toBeVisible();
	await page.getByTestId('import-start').click();
	const row = page.getByTestId('import-run').first();
	await expect(row.getByTestId('import-progress')).toContainText(/[1-9]\d* von 12 Dokumenten/, { timeout: 15_000 });
	await row.getByTestId('import-cancel').click();
	await expect(row.getByTestId('import-cancel-requested')).toBeVisible();
	await expect(row.getByTestId('import-cancel')).toHaveCount(0);
	await expect(row).toHaveAttribute('data-state', 'cancelled', { timeout: 15_000 });
	const report = page.getByTestId('import-report');
	await expect(report).toHaveAttribute('data-state', 'cancelled');
	await expect(report.getByTestId('import-cancelled-note')).toContainText('neuer Lauf');
	// archive numbers and owners are only counted by a run that reached the end: no misleading zeros
	await expect(report.getByTestId('import-asn')).toHaveCount(0);
	await expect(report.getByTestId('import-rights')).toContainText('nicht übernommen');
	await expect(report.getByTestId('import-rights')).not.toContainText('0 Besitzer');
	await expect(report.getByTestId('import-count-documents_imported')).toHaveText(/^[1-9]$|^1[01]$/);
});

test('AK-PA2-1 export directory, rejected requests and failed runs explain themselves', async ({ page, context }) => {
	await bootstrap(page, context);
	await openImport(page);

	// export source: no address and no token field
	await page.getByTestId('import-kind-export').check();
	await expect(page.getByTestId('import-token')).toHaveCount(0);
	await expect(page.getByTestId('import-base-url')).toHaveCount(0);
	await page.getByTestId('import-path').fill('../etc');
	await page.getByTestId('import-start').click();
	await expect(page.getByTestId('import-form-error')).toContainText('Verzeichnis');

	// a rejected address keeps the address, but the token field is empty again
	await page.getByTestId('import-kind-api').check();
	await page.getByTestId('import-base-url').fill('https://intern.example.org');
	await page.getByTestId('import-token').fill(TOKEN);
	await page.getByTestId('import-start').click();
	await expect(page.getByTestId('import-form-error')).toContainText('nicht freigegeben');
	await expect(page.getByTestId('import-token')).toHaveValue('');
	await expect(page.getByTestId('import-base-url')).toHaveValue('https://intern.example.org');
	// without typing it again there is no token to send
	await page.getByTestId('import-base-url').fill(ADDRESS);
	await page.getByTestId('import-start').click();
	await expect(page.getByTestId('import-form-error')).toContainText('Bitte trag das Token ein');

	// two runs against the same source
	await page.getByTestId('import-base-url').fill(`${ADDRESS}/slow`);
	await page.getByTestId('import-token').fill(TOKEN);
	await page.getByTestId('import-start').click();
	await expect(page.getByTestId('import-run')).toHaveCount(1);
	await page.getByTestId('import-token').fill(TOKEN);
	await page.getByTestId('import-start').click();
	await expect(page.getByTestId('import-form-error')).toContainText('läuft bereits');

	await page.getByTestId('import-base-url').fill(`${ADDRESS}/fail-auth`);
	await page.getByTestId('import-token').fill(TOKEN);
	await page.getByTestId('import-mode-import').check();
	await page.getByTestId('import-start').click();
	const failed = page.getByTestId('import-run').first();
	await expect(failed).toHaveAttribute('data-state', 'failed', { timeout: 15_000 });
	await expect(failed.getByTestId('import-run-error')).toContainText('Token');
	await expect(page.getByTestId('import-report')).toHaveAttribute('data-state', 'failed');
	// a run that read nothing shows its reason, not empty panels
	for (const panel of ['import-counts', 'import-findings', 'import-asn', 'import-rights']) await expect(page.getByTestId('import-report').getByTestId(panel)).toHaveCount(0);
	await expectNoSeriousA11y(page);
});

test('AK-PA2-1 a late answer of the run list does not hide a run started meanwhile', async ({ page, context }) => {
	await bootstrap(page, context);
	let release = () => {};
	const held = new Promise<void>((resolve) => (release = resolve));
	let first = true;
	await page.route('**/dms/imports', async (route) => {
		if (route.request().method() !== 'GET' || !first) return route.continue();
		first = false;
		// the answer is taken now (no run yet) and delivered after the start
		const response = await route.fetch();
		await held;
		await route.fulfill({ response });
	});
	await page.getByTestId('dms-nav-imports').click();
	await page.getByTestId('import-base-url').fill(ADDRESS);
	await page.getByTestId('import-token').fill(TOKEN);
	await page.getByTestId('import-start').click();
	// the run ends while the first answer is still on its way; nothing polls any more when it arrives
	await expect(page.getByTestId('import-run').first()).toHaveAttribute('data-state', 'done', { timeout: 15_000 });
	await expect(page.getByTestId('import-report')).toBeVisible();
	const late = page.waitForResponse((r) => r.request().method() === 'GET' && r.url().endsWith('/dms/imports'));
	release();
	await late;
	await page.waitForTimeout(1500);
	await expect(page.getByTestId('import-run')).toHaveCount(1);
});

test('AK-PA2-1 without the import permission there is no menu entry and no form', async ({ page, context, request }) => {
	await bootstrap(page, context);
	expect((await request.post('/api/__mock/dms/imports/deny')).status()).toBe(204);
	await page.reload();
	await expect(page.getByTestId('nav-dms')).toBeVisible();
	await expect(page.getByTestId('dms-nav-imports')).toHaveCount(0);
	await page.goto('/dms/imports');
	await expect(page.getByTestId('dms-forbidden')).toBeVisible();
	await expect(page.getByTestId('import-form')).toHaveCount(0);
});

test('AK-PA2-2 notes of a document are visible as plain text; a document without notes shows no section', async ({ page, context, request }) => {
	await bootstrap(page, context);
	const seed = async (data: Record<string, unknown>) => expect((await request.post('/api/__mock/dms/seed', { data: { count: 1, ...data } })).status()).toBe(204);
	await seed({ title: 'Ohne Notiz' });
	await seed({
		title: 'Mit Notizen',
		notes: [
			{ body: 'Zählerstand geprüft.\nZweite Zeile <img src=x onerror="window.__notexss=1">', noted_at: '2026-03-05T10:00:00Z', origin: 'paperless:note:3' },
			{ body: 'Nachgefragt bei der Musterstelle.', noted_at: null, origin: null }
		]
	});
	await page.goto('/dms');
	await page.getByTestId('dms-row').filter({ hasText: 'Mit Notizen' }).getByRole('link').first().click();
	const notes = page.getByTestId('dms-notes');
	await expect(notes.getByRole('heading', { name: 'Notizen' })).toBeVisible();
	await expect(notes.getByTestId('dms-note')).toHaveCount(2);
	await expect(notes.getByTestId('dms-note').first()).toContainText('Zählerstand geprüft.');
	await expect(notes.getByTestId('dms-note').first()).toContainText('<img src=x');
	await expect(notes.getByTestId('dms-note').first()).toContainText('aus Paperless');
	await expect(notes.getByTestId('dms-note').first()).toContainText('05.03.2026');
	await expect(notes.getByTestId('dms-note').last()).not.toContainText('aus Paperless');
	await expect(notes.locator('img')).toHaveCount(0);
	expect(await page.evaluate(() => (window as unknown as { __notexss?: number }).__notexss)).toBeUndefined();
	await expectNoSeriousA11y(page);

	await page.goto('/dms');
	await page.getByTestId('dms-row').filter({ hasText: 'Ohne Notiz' }).getByRole('link').first().click();
	await expect(page.getByTestId('dms-detail-title')).toHaveText('Ohne Notiz');
	await page.waitForLoadState('networkidle');
	await expect(page.getByTestId('dms-notes')).toHaveCount(0);
});

test('WP-D5b the integrity report shows what the orphan sweep removed', async ({ page, context }) => {
	await bootstrap(page, context);
	await page.getByTestId('dms-nav-integrity').click();
	await page.getByTestId('integrity-start').click();
	await expect(page.getByTestId('integrity-report')).toHaveAttribute('data-state', 'passed', { timeout: 15_000 });
	const orphans = page.getByTestId('integrity-orphans');
	await expect(orphans).toContainText('Verwaiste Dateien');
	await expect(orphans.getByTestId('orphans-blobs')).toHaveText('2');
	await expect(orphans.getByTestId('orphans-staging')).toHaveText('1');
	await expect(orphans.getByTestId('orphans-pending')).toHaveText('3');
	await expectNoSeriousA11y(page);
});
