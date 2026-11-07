import { describe, expect, it } from 'vitest';
import { formatDateTime, invitationLink, recoveryCodesFile } from './format';

describe('format helpers', () => {
	it('recoveryCodesFile lists one code per line below the title', () => {
		expect(recoveryCodesFile('Title', ['AAA', 'BBB'])).toBe('Title\n\nAAA\nBBB\n');
	});

	it('invitationLink prefers an absolute backend link and otherwise builds one from the origin', () => {
		expect(invitationLink('https://hub.example.org/invite/t', 't', 'http://localhost')).toBe('https://hub.example.org/invite/t');
		expect(invitationLink('/invite/t', 't', 'http://localhost')).toBe('http://localhost/invite/t');
		expect(invitationLink(undefined, 'tok', 'http://localhost')).toBe('http://localhost/invite/tok');
	});

	it('formatDateTime keeps an unparsable value', () => {
		expect(formatDateTime('not a date', 'de')).toBe('not a date');
		expect(formatDateTime('2030-01-02T03:04:00Z', 'en')).toMatch(/2030/);
	});
});
