import { expect, test, type Page } from '@playwright/test';
import { execFile, spawn, type ChildProcess } from 'node:child_process';
import { openSync } from 'node:fs';
import { promisify } from 'node:util';
import { addVirtualAuthenticator } from './virtual-authenticator';

// WP-H17 (Codex finding 8): an OCR job that failed for good must leave a VISIBLE and RESTARTABLE error state, and a retry stays consistent.
// Real backend, real Postgres, real worker process (`App worker --kinds dms.ocr`), no mocks. Run with scripts/e2e-dms-ocr-failure.sh
// (fresh database, backend with SETUP_TOKEN, builds nothing itself).
//
//   A. Regular final failure: a damaged PDF makes the handler fail permanently (`input_invalid`). Banner + retry button; the retry runs
//      through the real worker and fails again -> the banner is back (repeat stays consistent), the overview counts it as failed.
//   B. Crash-loop quarantine (the H17 gap): the job sits in the queue, its lease is expired maxAttempts times (controlled time in the database,
//      `lease_until` in the past), the next claim by the real worker quarantines the JOB. The ingest item must follow in the same transaction:
//      banner (`lease_expired`), overview counter failed, retry works once (second retry 409), the worker completes the document, banner gone.
//
// Needed: E2E_SETUP_TOKEN, E2E_DMS_FAILURE=1, E2E_APP_BIN (built `App`), E2E_DB_CONTAINER + E2E_DB_NAME (psql via `docker exec`), DB_* for the worker.
const execFileAsync = promisify(execFile);
const setupToken = process.env.E2E_SETUP_TOKEN;
const appBin = process.env.E2E_APP_BIN;
const dbContainer = process.env.E2E_DB_CONTAINER;
const dbName = process.env.E2E_DB_NAME;

test.skip(
	!setupToken || !process.env.E2E_DMS_FAILURE || !appBin || !dbContainer || !dbName,
	'E2E_SETUP_TOKEN/E2E_DMS_FAILURE/E2E_APP_BIN/E2E_DB_CONTAINER/E2E_DB_NAME not set: use scripts/e2e-dms-ocr-failure.sh'
);

async function sql(statement: string): Promise<string> {
	const { stdout } = await execFileAsync('docker', ['exec', dbContainer!, 'psql', '-U', 'labhub', '-d', dbName!, '-At', '-c', statement]);
	return stdout.trim();
}

let worker: ChildProcess | undefined;
function startWorker() {
	expect(worker).toBeUndefined();
	const log = process.env.E2E_WORKER_LOG ? openSync(process.env.E2E_WORKER_LOG, 'a') : 'ignore';
	worker = spawn(appBin!, ['worker', '--kinds', 'dms.ocr', '--poll-ms', '300'], { env: process.env, stdio: ['ignore', log, log] });
}
async function stopWorker() {
	const w = worker;
	worker = undefined;
	if (!w || w.exitCode !== null) return;
	await new Promise<void>((done) => {
		w.once('exit', () => done());
		w.kill('SIGTERM');
		setTimeout(() => w.kill('SIGKILL'), 5000).unref();
	});
}
test.afterAll(stopWorker);

/** One page with a real text layer (pdftotext path, no OCR tooling needed). */
function textPdf(lines: string[]): Buffer {
	const content = lines.map((l, i) => `BT /F1 14 Tf 72 ${760 - i * 24} Td (${l.replace(/[()\\]/g, '')}) Tj ET`).join('\n');
	const objs = [
		'<< /Type /Catalog /Pages 2 0 R >>',
		'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
		'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>',
		`<< /Length ${Buffer.byteLength(content)} >>\nstream\n${content}\nendstream`,
		'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'
	];
	let out = '%PDF-1.4\n';
	const offsets: number[] = [];
	objs.forEach((o, i) => {
		offsets.push(Buffer.byteLength(out));
		out += `${i + 1} 0 obj\n${o}\nendobj\n`;
	});
	const xref = Buffer.byteLength(out);
	out += `xref\n0 ${objs.length + 1}\n0000000000 65535 f \n${offsets.map((o) => `${String(o).padStart(10, '0')} 00000 n \n`).join('')}`;
	out += `trailer\n<< /Size ${objs.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
	return Buffer.from(out, 'latin1');
}

/** Damaged file with a PDF header: pdfinfo refuses it, the handler fails permanently (`input_invalid`). */
function damagedPdf(): Buffer {
	return Buffer.from('%PDF-1.4\nthis is not a pdf body, h17-damaged-fixture\n%%EOF\n', 'latin1');
}

async function login(page: Page, browserContext: Parameters<typeof addVirtualAuthenticator>[0]) {
	await addVirtualAuthenticator(browserContext, page);
	await page.goto('/setup');
	await page.getByLabel('Setup-Token').fill(setupToken!);
	await page.getByLabel('Kennung').fill('owner');
	await page.getByLabel('Anzeigename').fill('Owner Test');
	await page.getByRole('button', { name: 'Passkey anlegen und starten' }).click();
	await expect(page).toHaveURL(/\/dashboard$/);
	await page.goto('/settings/modules');
	await page.getByTestId('module-toggle-dms').click();
	await expect(page.getByTestId('nav-dms')).toBeVisible();
}

test('H17: final OCR failure is visible and restartable, the retry stays consistent (real backend, DB, worker)', async ({ browser }) => {
	test.setTimeout(240_000);
	const context = await browser.newContext();
	const page = await context.newPage();
	await login(page, context);

	// Tenant and module are set up; the overview is empty.
	await page.goto('/dms');
	await expect(page.getByTestId('dms-empty')).toBeVisible();

	// ---- A. Regular final failure (handler: permanent) -------------------------------------------------------------
	startWorker();
	await page.getByTestId('dms-file-input').setInputFiles({ name: 'beschaedigt.pdf', mimeType: 'application/pdf', buffer: damagedPdf() });
	const itemA = page.getByTestId('dms-upload-item').first();
	await expect(itemA).toHaveAttribute('data-state', 'quarantine', { timeout: 60_000 });
	await expect(page.getByTestId('dms-upload-retry-processing')).toBeVisible();
	await expect.poll(() => sql("SELECT state || '/' || error_code || '/' || resume_state FROM dms_ingest_items"), { timeout: 15_000 }).toMatch(/^failed_permanent\/input_invalid\//);
	await expect.poll(() => sql("SELECT state FROM jobs WHERE kind = 'dms.ocr'")).toBe('failed_permanent');

	// Detail page: banner with the error code and the retry button; retry runs through the worker and fails again (consistent repeat).
	await page.goto('/dms');
	await page.getByTestId('dms-row').first().getByRole('link').first().click();
	await expect(page.getByTestId('dms-quarantine-banner')).toContainText('input_invalid');
	await page.getByTestId('dms-processing-retry').click();
	await expect(page.getByTestId('dms-quarantine-banner')).toContainText('input_invalid', { timeout: 60_000 });
	await expect.poll(() => sql("SELECT state FROM dms_ingest_items")).toBe('failed_permanent');
	// The retry enqueued a NEW job (the first one stays as history); the item points to the new one, which also failed for good.
	await expect.poll(() => sql("SELECT count(*) || '/' || max(j.state) FROM jobs j WHERE j.kind = 'dms.ocr'")).toBe('2/failed_permanent');
	expect(await sql("SELECT j.state FROM jobs j JOIN dms_ingest_items i ON i.job_id = j.id")).toBe('failed_permanent');
	await stopWorker();

	// ---- B. Crash-loop quarantine of the job (core path, lease expired maxAttempts times) --------------------------------
	// No worker is running: the job of the second document stays queued. Controlled time: lease already expired, attempts = maxAttempts (3).
	await page.goto('/dms');
	const pdfB = textPdf(['Absturzschleife Quartalsabrechnung Wasserzaehler', 'Rechnungsnummer 2026-0815 Herbstmesse Bremen']);
	await page.getByTestId('dms-file-input').setInputFiles({ name: 'absturz.pdf', mimeType: 'application/pdf', buffer: pdfB });
	await expect(page.getByTestId('dms-upload-item').first()).toHaveAttribute('data-state', /processing|done/, { timeout: 30_000 });
	await expect.poll(() => sql("SELECT count(*) FROM jobs WHERE kind = 'dms.ocr' AND state = 'queued'")).toBe('1');
	await sql("UPDATE jobs SET state = 'running', attempts = 3, lease_owner = 'crashed', lease_until = now() - interval '1 second' WHERE kind = 'dms.ocr' AND state = 'queued'");
	const docB = await sql("SELECT i.document_id FROM dms_ingest_items i JOIN jobs j ON j.id = i.job_id WHERE j.state = 'running'");
	expect(docB).toMatch(/^[0-9a-f-]{36}$/);
	expect(await sql(`SELECT state FROM dms_ingest_items WHERE document_id = '${docB}'`)).toBe('ocr_queued');

	// The real worker claims: the quarantine hits the job, the trigger carries the ingest item along in the same transaction.
	startWorker();
	await expect.poll(() => sql(`SELECT state || '/' || error_code || '/' || resume_state FROM dms_ingest_items WHERE document_id = '${docB}'`), { timeout: 30_000 })
		.toBe('failed_permanent/lease_expired/ocr_queued');
	await expect.poll(() => sql("SELECT last_error FROM jobs WHERE kind = 'dms.ocr' AND state = 'failed_permanent' ORDER BY finished_at DESC LIMIT 1")).toBe('lease_expired');
	await stopWorker();

	// Visible: banner with the code on the detail page; the overview counts the failure (2 documents, none queued).
	await page.goto(`/dms/${docB}`);
	await expect(page.getByTestId('dms-quarantine-banner')).toContainText('lease_expired');
	const stats = await page.request.get(`/api/v1/tenants/${await sql(`SELECT tenant_id FROM dms_documents WHERE id = '${docB}'`)}/dms/stats`);
	expect(stats.status()).toBe(200);
	const counters = await stats.json();
	expect(counters.failed).toBe(2);
	expect(counters.queued).toBe(0);

	// Restartable: the retry button works once, the worker completes the document, the banner is gone.
	const tenant = await sql(`SELECT tenant_id FROM dms_documents WHERE id = '${docB}'`);
	const retryUrl = `/api/v1/tenants/${tenant}/dms/documents/${docB}/processing/retry`;
	startWorker();
	await page.getByTestId('dms-processing-retry').click();
	await expect.poll(() => sql(`SELECT state FROM dms_ingest_items WHERE document_id = '${docB}'`), { timeout: 60_000 }).toMatch(/^(ocr_done|classified|done)$/);
	await page.reload();
	await expect(page.getByTestId('dms-quarantine-banner')).toHaveCount(0);
	await expect.poll(() => sql(`SELECT state FROM dms_ingest_items WHERE document_id = '${docB}'`), { timeout: 60_000 }).toBe('done');
	await expect.poll(() => sql(`SELECT error_code IS NULL FROM dms_ingest_items WHERE document_id = '${docB}'`)).toBe('t');

	// A second retry on the recovered document is refused consistently (409), the state does not change.
	const session = await (await page.request.get('/api/v1/auth/session')).json();
	const again = await page.request.post(retryUrl, { headers: { 'X-CSRF-Token': session.csrf_token } });
	expect(again.status()).toBe(409);
	expect(await sql(`SELECT state FROM dms_ingest_items WHERE document_id = '${docB}'`)).toBe('done');
	const after = await (await page.request.get(`/api/v1/tenants/${tenant}/dms/stats`)).json();
	expect(after.failed).toBe(1); // only the damaged document remains failed
	expect(after.queued).toBe(0);
});
