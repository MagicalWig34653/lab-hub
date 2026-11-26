import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { de } from './i18n/de';
import { en } from './i18n/en';
import { dmsManifest } from './modules-impl/dms/manifest';

// WP-ST6 (user, 25.11.2026): the web app is "LAB hub", its modules are "docs", "invoice" and so on. Internal keys stay.
describe('WP-ST6 product and module names', () => {
	it('AK-ST6-1 the app title, app name and recovery file say "LAB hub"', () => {
		expect(readFileSync(join(process.cwd(), 'src', 'app.html'), 'utf8')).toContain('<title>LAB hub</title>');
		for (const catalogue of [de, en]) {
			expect(catalogue['app.name']).toBe('LAB hub');
			expect(catalogue['recovery.fileTitle']).toMatch(/^LAB hub /);
		}
	});

	it('AK-ST6-2 the module headings are "docs" in German and English; the module key stays "dms"', () => {
		expect(dmsManifest.key).toBe('dms');
		expect(dmsManifest.routePrefix).toBe('/dms');
		for (const messages of [dmsManifest.messages.de, dmsManifest.messages.en]) {
			expect([messages['nav.dms'], messages['dms.title'], messages['dms.nav.group.documents']]).toEqual(['docs', 'docs', 'docs']);
		}
	});
});
