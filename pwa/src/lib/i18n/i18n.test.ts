import { describe, expect, it } from 'vitest';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { de } from './de';
import { en } from './en';
import { detectLocale, errorMessage, format, i18n } from './index.svelte';
import { ApiError } from '../api/errors';
import { WebAuthnError } from '../webauthn';

const placeholders = (text: string) => [...text.matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort();

describe('AK-F1-4 i18n completeness', () => {
	it('de and en define exactly the same keys', () => {
		expect(Object.keys(en).sort()).toEqual(Object.keys(de).sort());
	});

	it('no value is empty and placeholders match between de and en', () => {
		for (const key of Object.keys(de) as (keyof typeof de)[]) {
			expect(de[key].trim(), `de ${key}`).not.toBe('');
			expect(en[key].trim(), `en ${key}`).not.toBe('');
			expect(placeholders(en[key]), `placeholders of ${key}`).toEqual(placeholders(de[key]));
		}
	});

	it('every Problem.code of the contract has an error.<code> text', () => {
		const yaml = readFileSync(join(process.cwd(), '..', 'contracts', 'openapi.yaml'), 'utf8');
		const block = /    Problem:\n[\s\S]*?code:\n[\s\S]*?enum:\n((?:\s+- \w+\n)+)/.exec(yaml);
		expect(block, 'Problem.code enum found in contract').not.toBeNull();
		const codes = [...block![1].matchAll(/- (\w+)/g)].map((m) => m[1]);
		expect(codes.length).toBeGreaterThan(10);
		for (const code of codes) {
			expect(`error.${code}` in de, `error.${code} in de`).toBe(true);
			expect(`error.${code}` in en, `error.${code} in en`).toBe(true);
		}
	});

	it('error.<key> entries beyond the contract exist for client codes and common statuses', () => {
		for (const key of ['error.network_error', 'error.session_ended', 'error.generic', 'error.status_500']) {
			expect(key in de).toBe(true);
		}
	});
});

describe('no user-facing text in components (heuristic)', () => {
	function svelteFiles(dir: string): string[] {
		return readdirSync(dir).flatMap((name) => {
			const path = join(dir, name);
			if (statSync(path).isDirectory()) return name === 'ui' ? [] : svelteFiles(path);
			return path.endsWith('.svelte') ? [path] : [];
		});
	}

	it('markup text nodes with letters are only {expressions}', () => {
		const root = join(process.cwd(), 'src');
		const offenders: string[] = [];
		const files = svelteFiles(root);
		expect(files.length).toBeGreaterThan(8);
		for (const file of files) {
			const markup = readFileSync(file, 'utf8')
				.replace(/<script[\s\S]*?<\/script>/g, '')
				.replace(/<style[\s\S]*?<\/style>/g, '')
				.replace(/<!--[\s\S]*?-->/g, '')
				.replace(/\{[^{}]*(\{[^{}]*\}[^{}]*)*\}/g, '');
			for (const match of markup.matchAll(/>([^<>]*[A-Za-zÄÖÜäöüß]{2,}[^<>]*)</g)) {
				offenders.push(`${file}: ${match[1].trim()}`);
			}
		}
		expect(offenders).toEqual([]);
	});
});

describe('i18n helpers', () => {
	it('format replaces placeholders and leaves unknown ones', () => {
		expect(format('Hi {name}, {x}', { name: 'Ada' })).toBe('Hi Ada, {x}');
	});

	it('detectLocale prefers stored choice, then browser language, then de', () => {
		expect(detectLocale('en', ['de-DE'])).toBe('en');
		expect(detectLocale(null, ['fr-FR', 'en-GB'])).toBe('en');
		expect(detectLocale(null, ['fr-FR'])).toBe('de');
		expect(detectLocale('xx', [])).toBe('de');
	});

	it('errorMessage maps problem codes, falls back to status, then generic', () => {
		i18n.set('en');
		expect(errorMessage(new ApiError(410, 'invitation_invalid'))).toBe(en['error.invitation_invalid']);
		expect(errorMessage(new ApiError(503, 'something_new'))).toBe(en['error.status_503']);
		expect(errorMessage(new ApiError(418, 'something_new'))).toBe(en['error.generic']);
		expect(errorMessage(new WebAuthnError('cancelled'))).toBe(en['webauthn.cancelled']);
		i18n.set('de');
		expect(errorMessage(new ApiError(0, 'network_error'))).toBe(de['error.network_error']);
		expect(errorMessage(new Error('x'))).toBe(de['error.generic']);
	});
});
