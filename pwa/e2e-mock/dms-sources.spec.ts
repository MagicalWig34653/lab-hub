import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { addVirtualAuthenticator } from '../e2e/virtual-authenticator';
import { MOCK_SETUP_TOKEN } from '../mock/api';

// WP-F5b against the mock backend (mock/dms-sources.ts): DMS sources, API tokens, scanner setup page, dashboard card.
// All data is synthetic. The password below is a test value that must never appear in the page.

const SECRET = 'S3cret-Test-Value-Only';

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

async function expectNoSeriousA11y(page: Page) {
	const result = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
	const bad = result.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
	expect(bad.map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).join(' | ')}`)).toEqual([]);
}

async function createMailSource(page: Page, name: string, host = 'imap.example.org', user = 'scan@example.org', password = SECRET) {
	await page.getByTestId('source-new-mail').click();
	await page.getByTestId('source-name').fill(name);
	await page.getByTestId('source-host').fill(host);
	await page.getByTestId('source-username').fill(user);
	await page.getByTestId('source-password').fill(password);
	await page.getByTestId('source-save').click();
}

const row = (page: Page, name: string) => page.getByTestId('source-row').filter({ hasText: name });

test('AK-F5b-1 mail source: create, never show the password, test, edit, run, disable, enable, delete', async ({ page, context }) => {
	await bootstrap(page, context);
	await page.getByTestId('dms-nav-sources').click();
	await expect(page.getByTestId('sources-empty')).toBeVisible();
	await expectNoSeriousA11y(page);

	// Create: client-side checks first, then the form saves.
	await page.getByTestId('source-new-mail').click();
	await expectNoSeriousA11y(page);
	await page.getByTestId('source-save').click();
	await expect(page.getByTestId('source-problems')).toContainText('Bitte gib einen Namen an.');
	await expect(page.getByTestId('source-problems')).toContainText('Bitte gib das Passwort an.');
	await expect(page.getByTestId('source-port')).toHaveValue('993');
	await expect(page.getByTestId('source-password')).toHaveAttribute('type', 'password');
	await page.getByTestId('source-cancel').click();

	await createMailSource(page, 'Posteingang');
	await expect(page.getByTestId('source-saved')).toContainText('Posteingang');
	const r = row(page, 'Posteingang');
	await expect(r.getByTestId('source-summary')).toContainText('scan@example.org @ imap.example.org:993');
	await expect(r.getByTestId('source-last-run')).toContainText('Noch kein Lauf');
	await expect(page.locator('body')).not.toContainText(SECRET);
	await expectNoSeriousA11y(page);

	// Test connection: success, then the TLS failure with a readable text.
	await r.getByTestId('source-test').click();
	await expect(r.getByTestId('source-test-result')).toHaveAttribute('data-ok', 'true');
	await expect(r.getByTestId('source-test-result')).toContainText('Passende ungelesene Nachrichten: 3');

	// Edit: the password stays hidden and empty; change the host to one that fails TLS.
	await r.getByTestId('source-edit').click();
	await expect(page.getByTestId('source-password')).toHaveValue('');
	await expect(page.getByTestId('source-password')).toHaveAttribute('placeholder', /Gespeichert/);
	await expect(page.locator('body')).not.toContainText(SECRET);
	await page.getByTestId('source-host').fill('imap.tls-fail.example.org');
	await page.getByTestId('source-save').click();
	await expect(page.getByTestId('source-saved')).toBeVisible();
	await expect(row(page, 'Posteingang').getByTestId('source-summary')).toContainText('imap.tls-fail.example.org');
	await row(page, 'Posteingang').getByTestId('source-test').click();
	await expect(row(page, 'Posteingang').getByTestId('source-test-result')).toHaveAttribute('data-code', 'imap_tls_failed');
	await expect(row(page, 'Posteingang').getByTestId('source-test-result')).toContainText('Zertifikat');
	await expectNoSeriousA11y(page);

	// Run: the failed run shows the error code as a text, counters stay empty; the dashboard counts the source.
	await row(page, 'Posteingang').getByTestId('source-run').click();
	await expect(row(page, 'Posteingang').getByTestId('source-note')).toBeVisible();
	await expect(row(page, 'Posteingang').getByTestId('source-error')).toHaveAttribute('data-code', 'imap_tls_failed');
	await expect(row(page, 'Posteingang').getByTestId('source-last-status')).toHaveText('Fehler');
	await page.goto('/dashboard');
	await expect(page.getByTestId('dms-card-sources')).toHaveText('1');
	await page.goto('/dms/sources');

	// Fix the host, run again: counters appear.
	await row(page, 'Posteingang').getByTestId('source-edit').click();
	await page.getByTestId('source-host').fill('imap.example.org');
	await page.getByTestId('source-save').click();
	await row(page, 'Posteingang').getByTestId('source-run').click();
	await expect(row(page, 'Posteingang').getByTestId('source-last-status')).toHaveText('erfolgreich');
	await expect(row(page, 'Posteingang').getByTestId('source-stats')).toContainText('aufgenommen: 2');
	await expect(row(page, 'Posteingang').getByTestId('source-stats')).toContainText('Duplikate: 1');

	// Disable and enable.
	await row(page, 'Posteingang').getByTestId('source-toggle').click();
	await expect(row(page, 'Posteingang')).toHaveAttribute('data-enabled', 'false');
	await expect(row(page, 'Posteingang').getByTestId('source-enabled-state')).toHaveText('Deaktiviert');
	await expect(row(page, 'Posteingang').getByTestId('source-run')).toBeDisabled();
	await row(page, 'Posteingang').getByTestId('source-toggle').click();
	await expect(row(page, 'Posteingang')).toHaveAttribute('data-enabled', 'true');

	// Delete with confirmation (Cancel first).
	await row(page, 'Posteingang').getByTestId('source-delete').click();
	await expectNoSeriousA11y(page);
	await page.getByTestId('source-delete-dialog-cancel').click();
	await expect(row(page, 'Posteingang')).toBeVisible();
	await row(page, 'Posteingang').getByTestId('source-delete').click();
	await page.getByTestId('source-delete-dialog-confirm').click();
	await expect(page.getByTestId('sources-empty')).toBeVisible();
});

test('AK-F5b-2 source errors: host not allowed, secret key missing, duplicate name, consume folder', async ({ page, context }) => {
	await bootstrap(page, context);
	await page.getByTestId('dms-nav-sources').click();

	await createMailSource(page, 'Gesperrt', 'blocked.example.org');
	await expect(page.getByTestId('source-field-errors')).toContainText('vom Betreiber nicht erlaubt');
	await expectNoSeriousA11y(page);
	await page.getByTestId('source-cancel').click();

	await createMailSource(page, 'Ohne Schlüssel', 'imap.example.org', 'u', 'no-key');
	await expect(page.getByTestId('source-field-errors')).toContainText('SECRET_KEY');
	await page.getByTestId('source-password').fill(SECRET);
	await page.getByTestId('source-save').click();
	await expect(page.getByTestId('source-saved')).toBeVisible();
	await row(page, 'Ohne Schlüssel').getByTestId('source-edit').click();
	await expect(page.getByTestId('source-password')).toHaveValue('');
	await page.getByTestId('source-cancel').click();

	await createMailSource(page, 'ohne schlüssel');
	await expect(page.getByTestId('error-banner')).toContainText('Eine Quelle mit diesem Namen gibt es schon.');
	await page.getByTestId('source-cancel').click();

	// Wrong login, missing mailbox and timeout come back as codes with texts.
	await createMailSource(page, 'Falsche Anmeldung', 'imap.example.org', 'wrong');
	await row(page, 'Falsche Anmeldung').getByTestId('source-test').click();
	await expect(row(page, 'Falsche Anmeldung').getByTestId('source-test-result')).toContainText('Anmeldung wurde abgelehnt');
	await createMailSource(page, 'Langsam', 'slow.example.org');
	await row(page, 'Langsam').getByTestId('source-test').click();
	await expect(row(page, 'Langsam').getByTestId('source-test-result')).toContainText('nicht rechtzeitig');

	// Consume folder: path preview, no connection test, run reports the folder error.
	await page.getByTestId('source-new-folder').click();
	await page.getByTestId('source-name').fill('Scans');
	await page.getByTestId('source-path').fill('../etc');
	await page.getByTestId('source-save').click();
	await expect(page.getByTestId('source-problems')).toContainText('relativ');
	await page.getByTestId('source-path').fill('scans/missing');
	await expect(page.getByTestId('source-path-preview')).toContainText('scans/missing');
	await expectNoSeriousA11y(page);
	await page.getByTestId('source-save').click();
	await expect(page.getByTestId('source-saved')).toBeVisible();
	const folder = row(page, 'Scans');
	await expect(folder.getByTestId('source-test')).toHaveCount(0);
	await expect(folder).toContainText('kann nicht getestet werden');
	await folder.getByTestId('source-run').click();
	await expect(folder.getByTestId('source-error')).toHaveAttribute('data-code', 'folder_not_found');
	await expect(folder.getByTestId('source-error')).toContainText('Ordner wurde nicht gefunden');
	await expectNoSeriousA11y(page);
});

test('AK-F5b-3 API tokens: create, shown exactly once with copy, list, revoke with confirmation', async ({ page, context }) => {
	await context.grantPermissions(['clipboard-read', 'clipboard-write']);
	await bootstrap(page, context);
	await page.getByTestId('dms-nav-tokens').click();
	await expect(page.getByTestId('tokens-empty')).toBeVisible();
	await expectNoSeriousA11y(page);

	// Validation first.
	await page.getByTestId('token-create').click();
	await expect(page.getByTestId('token-problem')).toContainText('Name');
	await page.getByTestId('token-name').fill('Netzwerkscanner');
	await page.getByTestId('token-days').fill('900');
	await page.getByTestId('token-create').click();
	await expect(page.getByTestId('token-problem')).toContainText('730');
	await page.getByTestId('token-days').fill('30');
	await page.getByTestId('token-create').click();

	// Shown once, with copy.
	const plain = page.getByTestId('token-plain');
	await expect(plain).toBeVisible();
	const token = (await plain.textContent()) ?? '';
	expect(token).toMatch(/^lhp_[A-Za-z0-9_-]{43}$/);
	await expectNoSeriousA11y(page);
	await page.getByTestId('token-copy').click();
	await expect(page.getByTestId('token-copied')).toBeVisible();
	expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(token);
	await expect(page.getByTestId('token-row')).toHaveCount(1);
	await expect(page.getByTestId('token-row')).not.toContainText(token);

	// Dismissed: gone for good, also after a reload; the list never carries the token.
	await page.getByTestId('token-dismiss').click();
	await expect(page.getByTestId('token-fresh')).toHaveCount(0);
	await page.reload();
	await expect(page.getByTestId('token-row')).toHaveCount(1);
	await expect(page.locator('body')).not.toContainText(token);
	await expect(page.getByTestId('token-state')).toHaveText('Aktiv');
	await expect(page.getByTestId('tokens-table')).toContainText('dms.upload');

	// Revoke: Cancel keeps it, confirm revokes (no second revoke button).
	await page.getByTestId('token-revoke').click();
	await expectNoSeriousA11y(page);
	await page.getByTestId('token-revoke-dialog-cancel').click();
	await expect(page.getByTestId('token-state')).toHaveText('Aktiv');
	await page.getByTestId('token-revoke').click();
	await page.getByTestId('token-revoke-dialog-confirm').click();
	await expect(page.getByTestId('token-state')).toHaveText('Widerrufen');
	await expect(page.getByTestId('token-row')).toHaveAttribute('data-state', 'revoked');
	await expect(page.getByTestId('token-revoke')).toHaveCount(0);
});

test('AK-F5b-4 scanner setup page: endpoint, header, curl example with the placeholder host', async ({ page, context }) => {
	await bootstrap(page, context);
	await page.getByTestId('dms-nav-scanner').click();
	await expect(page.getByTestId('scanner-title')).toBeVisible();
	await expect(page.getByTestId('scanner-endpoint')).toContainText('/api/v1/tenants/');
	await expect(page.getByTestId('scanner-endpoint')).toContainText('/dms/share');
	await expect(page.getByTestId('scanner-header')).toContainText('Authorization: Bearer lhp_');
	const curl = page.getByTestId('scanner-curl');
	await expect(curl).toContainText('https://hub.example.org/api/v1/tenants/');
	await expect(curl).toContainText('Content-Type: application/octet-stream');
	await expect(curl).toContainText('--data-binary @scan.pdf');
	await expectNoSeriousA11y(page);
	await page.getByTestId('scanner-to-tokens').click();
	await expect(page.getByTestId('tokens-title')).toBeVisible();
});

test('AK-F5b-5 keyboard: forms submit with Enter, dialogs trap focus and close with Escape, buttons are tabbable', async ({ page, context }) => {
	await bootstrap(page, context);
	await page.getByTestId('dms-nav-sources').click();
	await page.getByTestId('source-new-folder').focus();
	await page.keyboard.press('Enter');
	await page.getByTestId('source-name').focus();
	await page.keyboard.type('Tastatur');
	await page.keyboard.press('Tab');
	await expect(page.getByTestId('source-path')).toBeFocused();
	await page.keyboard.type('keyboard');
	await page.keyboard.press('Enter');
	await expect(page.getByTestId('source-saved')).toBeVisible();

	// Reach the delete button by Tab only, open the dialog with Enter: focus is on Cancel, Escape closes it.
	await page.getByTestId('source-edit').focus();
	await page.keyboard.press('Tab');
	await expect(page.getByTestId('source-delete')).toBeFocused();
	await page.keyboard.press('Enter');
	await expect(page.getByTestId('source-delete-dialog-cancel')).toBeFocused();
	await page.keyboard.press('Escape');
	await expect(page.getByTestId('source-delete-dialog')).not.toBeVisible();
	await expect(page.getByTestId('source-row')).toHaveCount(1);

	// Token form: type, Enter creates; the one-time box and the revoke dialog work without a mouse.
	await page.getByTestId('dms-nav-tokens').focus();
	await page.keyboard.press('Enter');
	await page.getByTestId('token-name').focus();
	await page.keyboard.type('Tastatur-Token');
	await page.keyboard.press('Enter');
	await expect(page.getByTestId('token-plain')).toBeVisible();
	await page.getByTestId('token-dismiss').focus();
	await page.keyboard.press('Enter');
	await expect(page.getByTestId('token-fresh')).toHaveCount(0);
	await page.getByTestId('token-revoke').focus();
	await page.keyboard.press('Enter');
	await expect(page.getByTestId('token-revoke-dialog-cancel')).toBeFocused();
	await page.keyboard.press('Tab');
	await expect(page.getByTestId('token-revoke-dialog-confirm')).toBeFocused();
	await page.keyboard.press('Enter');
	await expect(page.getByTestId('token-state')).toHaveText('Widerrufen');
});

test('AK-F5b-6 dashboard card "Verarbeitung" and the English UI of the new pages', async ({ page, context }) => {
	await bootstrap(page, context);
	await page.goto('/dashboard');
	const card = page.getByTestId('dms-processing-card');
	await expect(card).toBeVisible();
	await expect(page.getByTestId('dms-card-processing')).toHaveText('0');
	await expect(page.getByTestId('dms-card-suggestions')).toHaveText('0');
	await expect(page.getByTestId('dms-card-sources')).toHaveText('0');
	await expectNoSeriousA11y(page);

	await page.getByTestId('language-switch').selectOption('en');
	await expect(card).toContainText('Processing');
	await page.goto('/dms/sources');
	await expect(page.getByTestId('sources-title')).toHaveText('Sources');
	await page.getByTestId('source-new-mail').click();
	await expect(page.getByTestId('source-editor-title')).toHaveText('New mail source');
	await page.getByTestId('source-save').click();
	await expect(page.getByTestId('source-problems')).toContainText('Please enter a name.');
	await expectNoSeriousA11y(page);
	await page.goto('/dms/tokens');
	await expect(page.getByTestId('tokens-title')).toHaveText('API tokens');
	await expectNoSeriousA11y(page);
	await page.goto('/dms/scanner');
	await expect(page.getByTestId('scanner-title')).toHaveText('Set up a scanner or share menu');
	await expectNoSeriousA11y(page);
});
