import { describe, expect, it } from 'vitest';
import { safeNext } from './navigation';

describe('safeNext (login redirect target)', () => {
	it('accepts same-origin paths', () => {
		expect(safeNext('/dashboard?x=1')).toBe('/dashboard?x=1');
	});
	it.each(['//evil.example', 'https://evil.example', '/\\evil.example', '', null, undefined, 'dashboard'])(
		'rejects %s',
		(value) => {
			expect(safeNext(value)).toBe('/dashboard');
		}
	);
});
