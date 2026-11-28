import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { execFile } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { addVirtualAuthenticator } from './virtual-authenticator';

// WP-PA2 (AK-PA2-1 to PA2-3) against the REAL backend and a REAL worker (`App worker --kinds dms.import.paperless`) and a LOCAL
// paperless-ngx container with invented documents (scripts/paperless-e2e/seed.py). Started by scripts/e2e-paperless-pwa.sh,
// which brings up database, Paperless, a slowing relay (so progress and cancel are observable), backend and worker.
// With E2E_SCREENSHOT_DIR set, each state is photographed light and dark, desktop and phone.
const exec = promisify(execFile);
const env = process.env;
const setupToken = env.E2E_SETUP_TOKEN;

test.skip(!setupToken || !env.E2E_IMPORT, 'E2E_IMPORT not set: run scripts/e2e-paperless-pwa.sh');

async function expectNoSeriousA11y(page: Page) {
	const result = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
	const bad = result.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
	expect(bad.map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).join(' | ')}`)).toEqual([]);
}

const desktop = { width: 1280, height: 900 };
const phone = { width: 390, height: 844 };

async function shot(page: Page, name: string) {
	const dir = env.E2E_SCREENSHOT_DIR;
	if (!dir) return;
	mkdirSync(dir, { recursive: true });
	await page.mouse.move(0, 0);
	await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
	for (const [device, viewport] of [['desktop', desktop], ['phone', phone]] as const) {
		await page.setViewportSize(viewport);
		for (const mode of ['light', 'dark'] as const) {
			await page.emulateMedia({ colorScheme: mode });
			// the sticky header would otherwise be painted in the middle of a full page picture
			await page.evaluate(() => window.scrollTo(0, 0));
			await page.screenshot({ path: join(dir, `${name}-${device}-${mode}.png`), fullPage: true, animations: 'disabled' });
		}
	}
	await page.emulateMedia({ colorScheme: 'light' });
	await page.setViewportSize(desktop);
}

const stored = (page: Page) =>
	page.evaluate(async () => {
		const parts: string[] = [JSON.stringify({ ...localStorage }), JSON.stringify({ ...sessionStorage }), document.cookie, location.href, JSON.stringify(history.state ?? null)];
		for (const info of await indexedDB.databases()) parts.push(info.name ?? '');
		for (const key of await caches.keys()) for (const r of await (await caches.open(key)).keys()) parts.push(r.url);
		parts.push(document.documentElement.outerHTML);
		for (const input of document.querySelectorAll('input, textarea')) parts.push((input as HTMLInputElement).value);
		return parts.join('\n');
	});

interface PaperlessDoc {
	id: number;
	title: string;
	notes: { note: string }[];
}

test('AK-PA2 real: dry run, progress, cancel, resume, report, export source, notes; the token stays nowhere', async ({ page, context }) => {
	test.setTimeout(600_000);
	const token = env.E2E_PAPERLESS_TOKEN!;
	const direct = env.E2E_PAPERLESS_URL!;
	const slow = env.E2E_PAPERLESS_SLOW_URL!;

	// The truth comes from the instance itself.
	const truth = (await (
		await fetch(`${direct}/api/documents/?page_size=100`, { headers: { Authorization: `Token ${token}`, Accept: 'application/json; version=10' } })
	).json()) as { count: number; results: PaperlessDoc[] };
	const total = truth.count;
	const withNotes = truth.results.find((d) => d.notes.length > 0)!;
	expect(total).toBeGreaterThan(5);
	expect(withNotes).toBeTruthy();

	const logs: string[] = [];
	page.on('console', (m) => logs.push(m.text()));
	const carrying: string[] = [];
	page.on('request', (r) => {
		if (r.url().includes(token) || (r.postData() ?? '').includes(token) || Object.values(r.headers()).join(' ').includes(token)) carrying.push(`${r.method()} ${new URL(r.url()).pathname}`);
	});

	// 1. Operator bootstrap, module on, import page.
	await addVirtualAuthenticator(context, page);
	await page.goto('/setup');
	await page.getByLabel('Setup-Token').fill(setupToken!);
	await page.getByLabel('Kennung').fill('owner');
	await page.getByLabel('Anzeigename').fill('Owner Test');
	await page.getByRole('button', { name: 'Passkey anlegen und starten' }).click();
	await expect(page).toHaveURL(/\/dashboard$/);
	await page.goto('/settings/modules');
	await page.getByTestId('module-toggle-dms').click();
	await expect(page.getByTestId('nav-dms')).toBeVisible();
	await page.getByTestId('nav-dms').click();
	await expect(page.getByTestId('dms-nav-imports')).toBeVisible();
	await page.getByTestId('dms-nav-imports').click();
	await expect(page.getByTestId('import-empty')).toBeVisible();
	await expectNoSeriousA11y(page);

	const field = page.getByTestId('import-token');
	const rows = page.getByTestId('import-run');
	/** Submits the form and waits for the row of the new run, so no later check reads the row of the run before. */
	const submit = async () => {
		const before = await rows.count();
		await page.getByTestId('import-start').click();
		await expect(rows).toHaveCount(before + 1);
	};
	const fillApi = async (address: string, value: string, mode: 'dry_run' | 'import') => {
		await page.getByTestId('import-base-url').fill(address);
		await field.fill(value);
		await page.getByTestId(`import-mode-${mode}`).check();
	};
	const start = async (address: string, value: string, mode: 'dry_run' | 'import') => {
		await fillApi(address, value, mode);
		await submit();
		await expect(field).toHaveValue('');
	};
	const newest = page.getByTestId('import-run').first();
	const report = page.getByTestId('import-report');
	const documents = async () => {
		const tenant = ((await (await page.request.get('/api/v1/tenants')).json()) as { items: { id: string }[] }).items[0].id;
		const list = (await (await page.request.get(`/api/v1/tenants/${tenant}/dms/documents?limit=100`)).json()) as { items: unknown[] };
		return { tenant, count: list.items.length };
	};

	// 2. Source: address and token typed, not yet sent (the token is masked).
	await page.getByTestId('import-base-url').fill(slow);
	await field.fill(token);
	await expect(field).toHaveAttribute('type', 'password');
	await shot(page, '1-source');

	// 3. Dry run: progress while it runs, then the report; nothing is written.
	await page.getByTestId('import-start').click();
	await expect(field).toHaveValue('');
	await expect(newest.getByTestId('import-progress')).toContainText(new RegExp(`[1-9]\\d* von ${total} Dokumenten`), { timeout: 120_000 });
	await expect(newest.getByRole('progressbar')).toBeVisible();
	await shot(page, '2-progress');
	await expect(newest).toHaveAttribute('data-state', 'done', { timeout: 180_000 });
	await expect(report.getByTestId('import-dry-note')).toBeVisible();
	await expect(report.getByTestId('import-count-documents_seen')).toHaveText(String(total));
	await expect(report.getByTestId('import-count-documents_would_import')).toHaveText(String(total));
	await expect(report.getByTestId('import-visibility')).toContainText('Token');
	await expect(report.getByTestId('import-finding').first()).toBeVisible();
	await report.getByTestId('import-finding').first().locator('summary').click();
	expect((await documents()).count).toBe(0);
	await expectNoSeriousA11y(page);
	await shot(page, '3-dryrun-report');

	// 4. Import and cancel after the first documents.
	await start(slow, token, 'import');
	await expect(newest.getByTestId('import-progress')).toContainText(new RegExp(`[1-9]\\d* von ${total} Dokumenten`), { timeout: 120_000 });
	await newest.getByTestId('import-cancel').click();
	await expect(newest.getByTestId('import-cancel-requested').or(page.locator('[data-testid="import-run"][data-state="cancelled"]').first())).toBeVisible();
	await shot(page, '4-cancel-requested');
	await expect(newest).toHaveAttribute('data-state', 'cancelled', { timeout: 120_000 });
	await expect(report).toHaveAttribute('data-state', 'cancelled');
	await expect(report.getByTestId('import-cancelled-note')).toBeVisible();
	// archive numbers and owners are only counted by a run that reached the end
	await expect(report.getByTestId('import-asn')).toHaveCount(0);
	const afterCancel = (await documents()).count;
	expect(afterCancel).toBeGreaterThan(0);
	expect(afterCancel).toBeLessThan(total);
	await expect(report.getByTestId('import-count-documents_imported')).toHaveText(String(afterCancel));
	await shot(page, '5-cancelled-report');

	// 5. A new run against the same source continues: what is there is skipped, only the rest is imported.
	await start(slow, token, 'import');
	await expect(newest).toHaveAttribute('data-state', 'done', { timeout: 180_000 });
	await expect(report).toHaveAttribute('data-state', 'done');
	await expect(report.getByTestId('import-count-documents_seen')).toHaveText(String(total));
	await expect(report.getByTestId('import-count-documents_skipped_existing')).toHaveText(String(afterCancel));
	await expect(report.getByTestId('import-count-documents_imported')).toHaveText(String(total - afterCancel));
	await expect(report.getByTestId('import-asn')).toBeVisible();
	const final = await documents();
	expect(final.count).toBe(total);
	await expectNoSeriousA11y(page);
	await shot(page, '6-import-report');
	const download = page.waitForEvent('download');
	await report.getByTestId('import-download').click();
	expect((await download).suggestedFilename()).toMatch(/^paperless-import-report-[0-9a-f]{8}\.json$/);

	// 6. Export directory (document_exporter of the same instance) as a source.
	const target = join(env.E2E_IMPORT_ROOT!, final.tenant.toLowerCase());
	mkdirSync(target, { recursive: true });
	await exec('docker', ['cp', `${env.E2E_PAPERLESS_CONTAINER}:/usr/src/paperless/export`, join(target, 'paperless-export')]);
	await page.getByTestId('import-kind-export').check();
	await expect(field).toHaveCount(0);
	await page.getByTestId('import-path').fill('paperless-export');
	await page.getByTestId('import-mode-dry_run').check();
	await submit();
	await expect(newest).toHaveAttribute('data-state', 'done', { timeout: 120_000 });
	await expect(report.getByTestId('import-count-documents_seen')).toHaveText(String(total));
	await expect(report.getByTestId('import-visibility')).toContainText('Export');

	// 7. A wrong token and a refused address explain themselves.
	await page.getByTestId('import-kind-api').check();
	// as an import: the real backend adds `documents_imported: 0` even though nothing was read
	await start(direct, `wrong-${token.slice(0, 8)}`, 'import');
	await expect(newest).toHaveAttribute('data-state', 'failed', { timeout: 120_000 });
	await expect(newest.getByTestId('import-run-error')).toContainText('Token abgelehnt');
	await expect(report.getByTestId('import-report-error')).toContainText('Token abgelehnt');
	await expect(report.getByTestId('import-counts')).toHaveCount(0);
	await expect(report.getByTestId('import-asn')).toHaveCount(0);
	await shot(page, '7-failed');
	await fillApi('https://someone@paperless.example.org', 'placeholder', 'dry_run');
	await page.getByTestId('import-start').click();
	await expect(field).toHaveValue('');
	await expect(page.getByTestId('import-form-error')).toContainText('Die Adresse ist ungültig');

	// 8. The token went to the backend only in the requests that created runs, and the browser kept nothing of it.
	expect(new Set(carrying).size).toBe(1);
	expect(carrying[0]).toMatch(/^POST \/api\/v1\/tenants\/[0-9a-f-]+\/dms\/imports$/i);
	expect(carrying).toHaveLength(3);
	expect(await stored(page)).not.toContain(token);
	expect(logs.join('\n')).not.toContain(token);
	await page.reload();
	await expect(page.getByTestId('import-run').first()).toBeVisible();
	await expect(field).toHaveValue('');
	expect(await stored(page)).not.toContain(token);
	expect(await (await page.request.get(`/api/v1/tenants/${final.tenant}/dms/imports`)).text()).not.toContain(token);

	// 9. AK-PA2-2: the note of the document, imported from the instance, is visible at the document.
	await page.getByTestId('nav-dms').click();
	await page.getByTestId('dms-search').fill('');
	await page.getByTestId('dms-row').filter({ hasText: withNotes.title }).first().getByRole('link').first().click();
	await expect(page.getByTestId('dms-detail-title')).toHaveText(withNotes.title);
	const notes = page.getByTestId('dms-notes');
	await expect(notes.getByTestId('dms-note')).toHaveCount(withNotes.notes.length);
	for (const note of withNotes.notes) await expect(notes).toContainText(note.note);
	await expect(notes).toContainText('aus Paperless');
	await expectNoSeriousA11y(page);
	await shot(page, '8-notes');
});
