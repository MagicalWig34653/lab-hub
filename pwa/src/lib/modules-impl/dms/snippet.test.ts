import { describe, expect, it } from 'vitest';
import { parseSnippet } from './snippet';

describe('parseSnippet (AK-F4: markers become highlighting, never HTML)', () => {
	it('splits at U+E000/U+E001', () => {
		expect(parseSnippet('vor Treffer nach')).toEqual([
			{ text: 'vor ', mark: false },
			{ text: 'Treffer', mark: true },
			{ text: ' nach', mark: false }
		]);
	});

	it('keeps markup as inert text', () => {
		const parts = parseSnippet('<img src=x onerror=alert(1)> <b>x</b>');
		expect(parts.map((p) => p.text).join('')).toBe('<img src=x onerror=alert(1)> <b>x</b>');
		expect(parts.filter((p) => p.mark).map((p) => p.text)).toEqual(['<b>x</b>']);
	});

	it('tolerates unbalanced markers and empty input', () => {
		expect(parseSnippet('ab')).toEqual([
			{ text: 'a', mark: false },
			{ text: 'b', mark: true }
		]);
		expect(parseSnippet('ab').map((p) => p.text).join('')).toBe('ab');
		expect(parseSnippet(null)).toEqual([]);
		expect(parseSnippet('')).toEqual([]);
	});

	it('no marker characters survive in the output', () => {
		const text = parseSnippet('ab').map((p) => p.text).join('');
		expect(text).not.toMatch(/[]/);
	});
});
