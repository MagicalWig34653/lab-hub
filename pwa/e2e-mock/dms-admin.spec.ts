import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { addVirtualAuthenticator } from '../e2e/virtual-authenticator';
import { MOCK_SETUP_TOKEN } from '../mock/api';

// WP-F5 against the mock backend (mock/dms-admin.ts): review queue, rules with dry run, duplicates, master data,
// trash and purge, integrity check, export. All data is synthetic.

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

const pdf = (name: string, text: string) => ({ name, mimeType: 'application/pdf', buffer: Buffer.from(`%PDF-1.4\n% ${text}\n%%EOF\n`) });

async function expectNoSeriousA11y(page: Page) {
	const result = await new AxeBuilder({ page }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
	const bad = result.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
	expect(bad.map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).join(' | ')}`)).toEqual([]);
}

async function seed(page: Page, options: Record<string, unknown>) {
	expect((await page.request.post('/api/__mock/dms/seed', { data: options })).status()).toBe(204);
}

async function uploadAndWait(page: Page, ...files: ReturnType<typeof pdf>[]) {
	await page.getByTestId('dms-file-input').setInputFiles(files);
	await expect(page.getByTestId('dms-upload-item').first()).toHaveAttribute('data-state', 'done', { timeout: 15_000 });
	await expect(page.getByTestId('dms-upload-item').last()).toHaveAttribute('data-state', 'done', { timeout: 15_000 });
}

/** Rule "Rechnungen": text contains "Rechnung" -> type Rechnung and tag Steuer. Saved in suggest mode after a dry run. */
async function createRule(page: Page, name = 'Rechnungen') {
	await page.getByTestId('dms-nav-rules').click();
	await page.getByTestId('rule-new').click();
	await page.getByTestId('rule-name').fill(name);
	await page.getByTestId('rule-cond-value').fill('Rechnung');
	await page.getByTestId('rule-act-type').selectOption({ label: 'Rechnung' });
	await page.getByTestId('rule-act-tag-Steuer').check();
	await page.getByTestId('rule-save').click();
	await expect(page.getByTestId('rule-saved')).toBeVisible();
}

test('AK-F5-1 review workflow: rule -> upload -> suggestion with reason -> keyboard accept/reject -> stale hint', async ({ page, context }) => {
	await bootstrap(page, context);
	await createRule(page);
	await expect(page.getByTestId('rule-row')).toHaveCount(1);

	await page.getByTestId('dms-nav-documents').click();
	await uploadAndWait(page, pdf('eins.pdf', 'Rechnung Nummer 1 vom 2026-03-04'), pdf('zwei.pdf', 'Rechnung Nummer 2 aus dem Herbst'));

	await page.getByTestId('dms-nav-review').click();
	await expect(page.getByTestId('review-title')).toBeVisible();
	// two documents x (type, tag)
	await expect(page.getByTestId('review-row')).toHaveCount(4);
	await expect(page.getByTestId('review-count')).toContainText('4');
	// the reason of the rule is visible, and the proposed value is named, not an id
	const first = page.getByTestId('review-row').first();
	await expect(first.getByTestId('suggestion-reason')).toContainText('Regel "Rechnungen", Treffer "Rechnung"');
	await expect(first.getByTestId('suggestion-value')).toHaveText('Rechnung');
	await expectNoSeriousA11y(page);

	// roving tabindex: only the first row is in the tab order
	await expect(page.getByTestId('review-list').locator('[tabindex="0"]')).toHaveCount(4);
	await expect(page.getByTestId('review-row').nth(1).locator('[tabindex="0"]')).toHaveCount(0);

	// keyboard: A accepts the focused suggestion, focus moves on; R rejects; J/K move
	await first.getByTestId('suggestion-document').focus();
	await page.keyboard.press('a');
	await expect(page.getByTestId('review-row')).toHaveCount(3);
	await expect(page.getByTestId('review-announce')).toContainText('Angenommen');
	const acceptedTitle = ((await page.getByTestId('review-announce').innerText()).match(/Angenommen: (.+?): Dokumenttyp/) ?? [])[1];
	expect(acceptedTitle).toBeTruthy();
	await expect(page.getByTestId('review-row').first().getByTestId('suggestion-document')).toBeFocused();
	await page.keyboard.press('r');
	await expect(page.getByTestId('review-row')).toHaveCount(2);
	await expect(page.getByTestId('review-announce')).toContainText('Abgelehnt');
	await page.keyboard.press('j');
	await expect(page.getByTestId('review-row').nth(1).getByTestId('suggestion-document')).toBeFocused();
	await page.keyboard.press('k');
	await expect(page.getByTestId('review-row').first().getByTestId('suggestion-document')).toBeFocused();

	// the accepted suggestion changed the document (type Rechnung), the rejected one did not add its tag
	await page.getByTestId('dms-nav-documents').click();
	await page.getByTestId('dms-row').filter({ hasText: acceptedTitle }).getByRole('link').first().click();
	await expect(page.getByTestId('dms-detail-title')).toHaveText(acceptedTitle);
	await expect(page.getByTestId('dms-edit-type').locator('option:checked')).toHaveText('Rechnung');

	// stale: the tag disappears from the master data -> hint, accept is disabled, reject still works
	await page.getByTestId('dms-nav-masters').click();
	await page.getByTestId('masters-tab-tags').click();
	await page.getByTestId('masters-row').filter({ hasText: 'Steuer' }).getByTestId('masters-delete').click();
	await page.getByTestId('masters-delete-dialog-confirm').click();
	await expect(page.getByTestId('masters-row').filter({ hasText: 'Steuer' })).toHaveCount(0);
	await page.getByTestId('dms-nav-review').click();
	const stale = page.getByTestId('review-row').filter({ has: page.getByTestId('suggestion-stale') });
	await expect(stale).toHaveCount(await page.getByTestId('review-row').count());
	await expect(stale.first().getByTestId('suggestion-accept')).toBeDisabled();
	await expect(stale.first().getByTestId('suggestion-stale')).toContainText('Veraltet');
	await expectNoSeriousA11y(page);
	const remaining = await page.getByTestId('review-row').count();
	for (let i = 0; i < remaining; i++) await page.getByTestId('review-row').first().getByTestId('suggestion-reject').click();
	await expect(page.getByTestId('review-empty')).toBeVisible();
});

test('AK-F5-1 review: suggestion of a rule in the document detail', async ({ page, context }) => {
	await bootstrap(page, context);
	await createRule(page);
	await page.getByTestId('dms-nav-documents').click();
	await uploadAndWait(page, pdf('eins.pdf', 'Rechnung Nummer 7'));
	await page.getByTestId('dms-row').first().getByRole('link').first().click();
	const card = page.getByTestId('doc-suggestion').first();
	await expect(card).toBeVisible();
	await card.getByTestId('suggestion-accept').click();
	await expect(page.getByTestId('doc-suggestion')).toHaveCount(1);
	await expect(page.getByTestId('dms-edit-type').locator('option:checked')).toHaveText('Rechnung');
});

test('AK-F5-2 rule with dry run: hits before saving, invalid regex, time limit, auto needs a current dry run', async ({ page, context }) => {
	await bootstrap(page, context);
	await seed(page, { count: 3, title: 'Mietvertrag' });
	await page.getByTestId('dms-nav-rules').click();
	await expect(page.getByTestId('rules-empty')).toBeVisible();
	await expectNoSeriousA11y(page);
	await page.getByTestId('rule-new').click();
	await page.getByTestId('rule-name').fill('Seeds');

	// nothing is stored before saving: dry run shows the hits with the found text and the resulting suggestions
	await page.getByTestId('rule-cond-value').fill('seed');
	await page.getByTestId('rule-act-type').selectOption({ label: 'Vertrag' });
	await page.getByTestId('rule-preview-run').click();
	await expect(page.getByTestId('rule-preview-summary')).toContainText('3 Dokumente geprüft, 3 Treffer');
	await expect(page.getByTestId('rule-preview-row')).toHaveCount(3);
	await expect(page.getByTestId('rule-preview-row').first()).toContainText('seed');
	await expect(page.getByTestId('rule-preview-row').first()).toContainText('Vertrag');
	await expectNoSeriousA11y(page);

	// auto mode needs a dry run of exactly these settings
	await page.getByTestId('rule-mode').selectOption('auto');
	await expect(page.getByTestId('rule-save')).toBeDisabled();
	await expect(page.getByTestId('rule-auto-needs-preview')).toBeVisible();
	await expect(page.getByTestId('rule-preview-outdated')).toBeVisible();
	await page.getByTestId('rule-preview-run').click();
	await expect(page.getByTestId('rule-preview-outdated')).toHaveCount(0);
	await expect(page.getByTestId('rule-save')).toBeEnabled();
	await page.getByTestId('rule-cond-value').fill('seed ');
	await expect(page.getByTestId('rule-preview-outdated')).toBeVisible();
	await expect(page.getByTestId('rule-save')).toBeDisabled();
	await page.getByTestId('rule-mode').selectOption('suggest');
	await expect(page.getByTestId('rule-save')).toBeEnabled();

	// an invalid regular expression is reported with the field
	await page.getByTestId('rule-cond-type').selectOption('text_regex');
	await page.getByTestId('rule-cond-value').fill('([');
	await page.getByTestId('rule-preview-run').click();
	await expect(page.getByTestId('error-banner')).toBeVisible();
	await expect(page.getByTestId('rule-field-errors')).toContainText('invalid_regex');

	// a pattern that exceeds the time limit shows the warning and counts as not met
	await page.getByTestId('rule-cond-value').fill('(a+)+$');
	await page.getByTestId('rule-cond-value').blur();
	await seed(page, { count: 1, title: 'aaaaaaaaaaaaaaaa' }); // title only; text of the seed has no a-run
	await page.getByTestId('rule-preview-run').click();
	await expect(page.getByTestId('rule-preview-summary')).toBeVisible();

	// save a valid rule, edit it, delete it with confirmation
	await page.getByTestId('rule-cond-value').fill('seed');
	await page.getByTestId('rule-save').click();
	await expect(page.getByTestId('rule-saved')).toBeVisible();
	const row = page.getByTestId('rule-row');
	await expect(row).toHaveCount(1);
	await expect(row.getByTestId('rule-mode-cell')).toHaveText('Vorschlagen');
	await row.getByTestId('rule-edit').click();
	await expect(page.getByTestId('rule-name')).toHaveValue('Seeds');
	await page.getByTestId('rule-cancel').click();
	await row.getByTestId('rule-delete').click();
	await page.getByTestId('rule-delete-dialog-confirm').click();
	await expect(page.getByTestId('rules-empty')).toBeVisible();
});

test('AK-F5-2 time limit of a regular expression is shown in the dry run', async ({ page, context }) => {
	await bootstrap(page, context);
	await page.getByTestId('dms-file-input').setInputFiles(pdf('a.pdf', 'xx aaaaaaaaaaaaaaaaaaaaaaaaaaaa yy'));
	await expect(page.getByTestId('dms-upload-item')).toHaveAttribute('data-state', 'done', { timeout: 15_000 });
	await page.getByTestId('dms-nav-rules').click();
	await page.getByTestId('rule-new').click();
	await page.getByTestId('rule-name').fill('Langsam');
	await page.getByTestId('rule-cond-type').selectOption('text_regex');
	await page.getByTestId('rule-cond-value').fill('(a+)+$');
	await page.getByTestId('rule-act-type').selectOption({ label: 'Brief' });
	await page.getByTestId('rule-preview-run').click();
	await expect(page.getByTestId('rule-preview-timeout')).toContainText('Zeitlimit');
	await expect(page.getByTestId('rule-preview-none')).toBeVisible();
	await expectNoSeriousA11y(page);
});

test('AK-F5-3 trash and purge: retention and blockers visible, owner confirmation, deletion log', async ({ page, context }) => {
	await bootstrap(page, context);
	await seed(page, { count: 1, trashed: true, doc_date: '2005-03-01', title: 'Alter Beleg' });
	await seed(page, { count: 1, trashed: true, doc_date: new Date().toISOString().slice(0, 10), title: 'Frischer Beleg' });
	await page.getByTestId('dms-nav-trash').click();
	await expect(page.getByTestId('trash-row')).toHaveCount(2);
	const old = page.getByTestId('trash-row').filter({ hasText: 'Alter Beleg' });
	const fresh = page.getByTestId('trash-row').filter({ hasText: 'Frischer Beleg' });
	await expect(old.getByTestId('trash-retention-until')).toContainText('2015');
	await expect(old.getByTestId('trash-purge-state')).toContainText('Möglich');
	await expect(fresh.getByTestId('trash-purge-state')).toContainText('Aufbewahrungsfrist ist noch nicht abgelaufen');
	await expect(fresh.getByTestId('trash-purge')).toBeDisabled();
	await expectNoSeriousA11y(page);

	// a legal hold blocks the purge and can be released
	await old.getByTestId('trash-hold-toggle').click();
	await expect(old.getByTestId('trash-legal-hold')).toHaveText('Ja');
	await expect(old.getByTestId('trash-purge-state')).toContainText('Löschsperre');
	await expect(old.getByTestId('trash-purge')).toBeDisabled();
	await old.getByTestId('trash-hold-toggle').click();
	await expect(old.getByTestId('trash-purge')).toBeEnabled();

	// purge needs the dialog and an explicit acknowledgement; cancel keeps the document
	await old.getByTestId('trash-purge').click();
	await expect(page.getByTestId('purge-dialog')).toBeVisible();
	await expect(page.getByTestId('purge-dialog-text')).toContainText('Alter Beleg');
	await expect(page.getByTestId('purge-dialog-confirm')).toBeDisabled();
	await expectNoSeriousA11y(page);
	await page.keyboard.press('Escape');
	await expect(page.getByTestId('purge-dialog')).toBeHidden();
	await expect(page.getByTestId('trash-row')).toHaveCount(2);

	await old.getByTestId('trash-purge').click();
	await page.getByTestId('purge-ack').check();
	await expect(page.getByTestId('purge-dialog-confirm')).toBeEnabled();
	await page.getByTestId('purge-dialog-confirm').click();
	await expect(page.getByTestId('trash-notice')).toContainText('endgültig gelöscht');
	await expect(page.getByTestId('trash-row')).toHaveCount(1);
	await expect(page.getByTestId('deletion-log-row')).toHaveCount(1);
	await expect(page.getByTestId('deletion-log')).not.toContainText('Alter Beleg');

	// restore brings a document back to the list
	await fresh.getByTestId('trash-restore').click();
	await expect(page.getByTestId('trash-empty')).toBeVisible();
});

test('AK-F5-3 purge is for the owner only: a member sees no purge button; the page is hidden without trash right', async ({ page, context, browser }) => {
	await bootstrap(page, context);
	await seed(page, { count: 1, trashed: true, doc_date: '2005-03-01', title: 'Alter Beleg' });
	await page.goto('/settings/members');
	await page.locator('#invite-role').selectOption('member');
	await page.getByTestId('invite-create').click();
	const link = (await page.getByTestId('invite-link').innerText()).trim();
	const invitePath = link.startsWith('http') ? new URL(link).pathname : link;
	const other = await browser.newContext();
	const member = await other.newPage();
	await addVirtualAuthenticator(other, member);
	await member.goto(invitePath);
	await member.getByLabel('Kennung').fill('mitglied');
	await member.getByLabel('Anzeigename').fill('Mitglied');
	await member.getByRole('button', { name: 'Passkey anlegen' }).click();
	await expect(member).toHaveURL(/\/dashboard$/);
	await member.goto('/dms/trash');
	await expect(member.getByTestId('dms-forbidden')).toBeVisible();
	await expect(member.getByTestId('dms-nav-trash')).toHaveCount(0);
	await member.goto('/dms/integrity');
	await expect(member.getByTestId('dms-forbidden')).toBeVisible();
	await other.close();
});

test('AK-F5-4 export: start, status, download', async ({ page, context }) => {
	await bootstrap(page, context);
	await uploadAndWait(page, pdf('eins.pdf', 'Beleg eins'));
	await page.getByTestId('dms-nav-exports').click();
	await expect(page.getByTestId('exports-empty')).toBeVisible();
	await expectNoSeriousA11y(page);
	await page.getByTestId('export-start').click();
	const row = page.getByTestId('export-row').first();
	await expect(row).toHaveAttribute('data-state', 'running');
	await expect(row).toHaveAttribute('data-state', 'done', { timeout: 10_000 });
	await expect(row.getByTestId('export-documents')).toHaveText('1');
	const href = await row.getByTestId('export-download').getAttribute('href');
	const response = await page.request.get(href!);
	expect(response.status()).toBe(200);
	expect(response.headers()['content-type']).toContain('application/zip');
	await expectNoSeriousA11y(page);

	// an invalid range is rejected before the request
	await page.getByTestId('export-from').fill('2026-05-01');
	await page.getByTestId('export-to').fill('2026-01-01');
	await page.getByTestId('export-start').click();
	await expect(page.getByTestId('error-banner')).toContainText('liegt nach');
});

test('AK-F5-5 integrity check: run, report, head hash; a tampered file fails the run and the export', async ({ page, context }) => {
	await bootstrap(page, context);
	await page.getByTestId('dms-nav-integrity').click();
	await expect(page.getByTestId('integrity-empty')).toBeVisible();
	await expect(page.getByTestId('integrity-head-none')).toBeVisible();
	await page.getByTestId('integrity-start').click();
	await expect(page.getByTestId('integrity-run').first()).toHaveAttribute('data-state', 'passed', { timeout: 10_000 });
	await expect(page.getByTestId('integrity-passed')).toBeVisible();
	await expect(page.getByTestId('integrity-head')).toHaveText(/^[0-9a-f]{64}$/);
	await expectNoSeriousA11y(page);

	await seed(page, { count: 1, tamper: true, title: 'Veraendert' });
	await page.getByTestId('integrity-start').click();
	await expect(page.getByTestId('integrity-run').first()).toHaveAttribute('data-state', 'failed', { timeout: 10_000 });
	await expect(page.getByTestId('integrity-failed')).toContainText('1 Abweichungen');
	await expect(page.getByTestId('integrity-finding')).toContainText('Prüfsumme weicht ab');
	await expectNoSeriousA11y(page);

	await page.getByTestId('dms-nav-exports').click();
	await page.getByTestId('export-start').click();
	await expect(page.getByTestId('export-row').first()).toHaveAttribute('data-state', 'failed', { timeout: 10_000 });
	await expect(page.getByTestId('export-error')).toContainText('Prüfsumme');
});

test('duplicates: same file twice -> hint, side by side comparison, decision', async ({ page, context }) => {
	await bootstrap(page, context);
	const same = pdf('kopie.pdf', 'Identischer Inhalt');
	await uploadAndWait(page, same);
	await page.getByTestId('dms-file-input').setInputFiles({ ...same, name: 'kopie-2.pdf' });
	await expect(page.getByTestId('dms-upload-item').last()).toHaveAttribute('data-state', /duplicate|done/, { timeout: 15_000 });
	await page.getByTestId('dms-nav-duplicates').click();
	await expect(page.getByTestId('duplicate-row')).toHaveCount(1);
	await expect(page.getByTestId('duplicate-meta')).toContainText('Gleiche Datei');
	await page.getByTestId('duplicate-compare').click();
	await expect(page.getByTestId('duplicate-table')).toBeVisible();
	await expect(page.getByTestId('duplicate-table')).toContainText('kopie');
	await expectNoSeriousA11y(page);
	await page.getByTestId('duplicate-confirm').click();
	await expect(page.getByTestId('duplicates-empty')).toBeVisible();
	await page.getByTestId('duplicates-state').selectOption('confirmed');
	await expect(page.getByTestId('duplicate-row')).toHaveCount(1);
	await expect(page.getByTestId('duplicate-row')).toHaveAttribute('data-state', 'confirmed');
});

test('master data: create, rename, delete a tag; a custom field cannot change its code; in use blocks deleting', async ({ page, context }) => {
	await bootstrap(page, context);
	await page.getByTestId('dms-nav-masters').click();
	await expect(page.getByTestId('masters-title')).toBeVisible();
	await expectNoSeriousA11y(page);

	await page.getByTestId('masters-tab-tags').click();
	await expect(page.getByTestId('masters-merge-note')).toBeVisible();
	await page.getByTestId('masters-new').click();
	await page.getByTestId('masters-f-name').fill('Garantie');
	await page.getByTestId('masters-save').click();
	await expect(page.getByTestId('masters-row').filter({ hasText: 'Garantie' })).toHaveCount(1);
	await page.getByTestId('masters-row').filter({ hasText: 'Garantie' }).getByTestId('masters-edit').click();
	await page.getByTestId('masters-f-name').fill('Gewährleistung');
	await page.getByTestId('masters-save').click();
	await expect(page.getByTestId('masters-row').filter({ hasText: 'Gewährleistung' })).toHaveCount(1);
	await expect(page.getByTestId('masters-row').filter({ hasText: 'Garantie' })).toHaveCount(0);

	// same name again -> conflict message
	await page.getByTestId('masters-new').click();
	await page.getByTestId('masters-f-name').fill('gewährleistung');
	await page.getByTestId('masters-save').click();
	await expect(page.getByTestId('masters-form-error')).toBeVisible();
	await page.getByTestId('masters-cancel').click();

	await page.getByTestId('masters-row').filter({ hasText: 'Gewährleistung' }).getByTestId('masters-delete').click();
	await expect(page.getByTestId('masters-delete-dialog')).toBeVisible();
	await page.getByTestId('masters-delete-dialog-confirm').click();
	await expect(page.getByTestId('masters-row').filter({ hasText: 'Gewährleistung' })).toHaveCount(0);

	// document types carry the retention period in years
	await page.getByTestId('masters-tab-types').click();
	await page.getByTestId('masters-new').click();
	await page.getByTestId('masters-f-name').fill('Lohnabrechnung');
	await page.getByTestId('masters-f-default_retention_years').fill('6');
	await page.getByTestId('masters-save').click();
	await expect(page.getByTestId('masters-row').filter({ hasText: 'Lohnabrechnung' })).toContainText('6');
	await page.getByTestId('masters-tab-custom-fields').click();
	await page.getByTestId('masters-row').first().getByTestId('masters-edit').click();
	await expect(page.getByTestId('masters-f-code')).toHaveCount(0);
	await expectNoSeriousA11y(page);
});

test('English UI of the new pages', async ({ page, context }) => {
	await bootstrap(page, context);
	await page.getByTestId('language-switch').selectOption('en');
	await page.getByTestId('dms-nav-review').click();
	await expect(page.getByTestId('review-title')).toHaveText('Review');
	await expect(page.getByTestId('review-empty')).toContainText('No open suggestions');
	await page.getByTestId('dms-nav-trash').click();
	await expect(page.getByTestId('trash-title')).toHaveText('Trash and deletion policy');
	await expectNoSeriousA11y(page);
});
