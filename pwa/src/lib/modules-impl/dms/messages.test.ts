import { describe, expect, it } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { dmsManifest } from './manifest';

const placeholders = (text: string) => [...text.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();
const { de, en } = dmsManifest.messages;

describe('WP-F4 i18n de/en completeness for the DMS module', () => {
	it('de and en define the same keys, non-empty, with the same placeholders', () => {
		expect(Object.keys(en).sort()).toEqual(Object.keys(de).sort());
		for (const key of Object.keys(de)) {
			expect(de[key].trim(), `de ${key}`).not.toBe('');
			expect(en[key].trim(), `en ${key}`).not.toBe('');
			expect(placeholders(en[key]), `placeholders of ${key}`).toEqual(placeholders(de[key]));
		}
	});

	it('every dms.* key referenced in the DMS sources exists in both languages', () => {
		const dirs = [join(process.cwd(), 'src', 'lib', 'modules-impl', 'dms'), join(process.cwd(), 'src', 'routes', '(app)', 'dms')];
		const files: string[] = [];
		const walk = (dir: string) => {
			for (const entry of readdirSync(dir, { withFileTypes: true })) {
				const path = join(dir, entry.name);
				if (entry.isDirectory()) walk(path);
				else if (/\.(svelte|ts)$/.test(entry.name) && !/\.test\.ts$/.test(entry.name) && entry.name !== 'manifest.ts') files.push(path);
			}
		};
		dirs.forEach(walk);
		expect(files.length).toBeGreaterThan(5);
		const used = new Set<string>();
		for (const file of files) {
			for (const m of readFileSync(file, 'utf8').matchAll(/'(dms\.[A-Za-z0-9_.]+)'/g)) {
				// Permission names (dms.document.read …) are not texts.
				if (!m[1].startsWith('dms.document.')) used.add(m[1]);
			}
		}
		expect(used.size).toBeGreaterThan(40);
		const missing = [...used].filter((key) => !(key in de) || !(key in en));
		expect(missing).toEqual([]);
	});

	it('no manifest key is unused (no dead texts)', () => {
		const sources = [
			join(process.cwd(), 'src', 'lib', 'modules-impl', 'dms', 'DmsBrowser.svelte'),
			join(process.cwd(), 'src', 'lib', 'modules-impl', 'dms', 'DocumentDetail.svelte'),
			join(process.cwd(), 'src', 'lib', 'modules-impl', 'dms', 'UploadPanel.svelte'),
			join(process.cwd(), 'src', 'routes', '(app)', 'dms', '+page.svelte')
		]
			.map((f) => readFileSync(f, 'utf8'))
			.join('\n');
		const unused = Object.keys(de).filter((key) => key !== 'nav.dms' && !sources.includes(`'${key}'`));
		expect(unused).toEqual([]);
	});
});
