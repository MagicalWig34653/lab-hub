import { describe, expect, it } from 'vitest';
import { createInput, emptyFolder, emptyMail, fieldErrorKey, folderConfig, mailConfig, sourceErrorKey, validateFolder, validateMail } from './sources';

describe('WP-F5b source drafts', () => {
	it('a valid mail draft converts to the contract config without empty optional fields', () => {
		const draft = { ...emptyMail(), host: 'IMAP.Example.org', username: 'scan@example.org', password: 'pw' };
		expect(validateMail(draft, 'Posteingang', false)).toEqual([]);
		expect(mailConfig(draft)).toEqual({
			host: 'imap.example.org',
			port: 993,
			username: 'scan@example.org',
			mailbox: 'INBOX',
			interval_seconds: 120,
			include_body: false,
			max_per_run: 50
		});
	});

	it('the password is required on create only and is sent only on create', () => {
		const draft = { ...emptyMail(), host: 'imap.example.org', username: 'u' };
		expect(validateMail(draft, 'x', false)).toContain('passwordRequired');
		expect(validateMail(draft, 'x', true)).not.toContain('passwordRequired');
		expect(createInput('mail', ' x ', { ...draft, password: 'pw' })).toMatchObject({ kind: 'mail', name: 'x', password: 'pw', enabled: true });
		expect(createInput('folder', 'f', { ...emptyFolder(), path: 'inbox' })).not.toHaveProperty('password');
	});

	it('validates ranges and the ASCII limit of the backend', () => {
		const bad = { ...emptyMail(), host: 'bad host', port: '0', username: '', interval_seconds: '5', max_per_run: '500', mailbox: 'Pöst' };
		expect(validateMail(bad, '', false).sort()).toEqual(['asciiOnly', 'hostInvalid', 'maxInvalid', 'nameRequired', 'passwordRequired', 'portInvalid', 'mailIntervalInvalid', 'usernameRequired'].sort());
	});

	it('folder paths are relative, limited to the allowed characters and free of dot segments', () => {
		expect(validateFolder({ ...emptyFolder(), path: 'scans/2026' }, 'f')).toEqual([]);
		for (const path of ['', '/abs', '../x', 'a/../b', 'a//b', 'a;b', './a']) {
			expect(validateFolder({ ...emptyFolder(), path }, 'f').length, path).toBeGreaterThan(0);
		}
		expect(folderConfig({ path: ' scans ', interval_seconds: '60', stable_seconds: '0' })).toEqual({ path: 'scans', interval_seconds: 60, stable_seconds: 0 });
	});

	it('accepts the numbers a bound number input hands over at runtime', () => {
		const draft = { ...emptyMail(), host: 'imap.example.org', username: 'u', password: 'p', port: 143 as unknown as string, interval_seconds: 60 as unknown as string };
		expect(validateMail(draft, 'x', false)).toEqual([]);
		expect(mailConfig(draft)).toMatchObject({ port: 143, interval_seconds: 60 });
		expect(validateMail({ ...draft, port: null as unknown as string }, 'x', false)).toContain('portInvalid');
	});

	it('maps error codes to texts and unknown ones to a generic text', () => {
		expect(sourceErrorKey('imap_tls_failed')).toBe('dms.sources.error.imap_tls_failed');
		expect(sourceErrorKey('something_new')).toBe('dms.sources.error.unknown');
		expect(fieldErrorKey('password', 'secret_key_missing')).toBe('dms.sources.error.secret_key_missing');
		expect(fieldErrorKey('config.host', 'invalid')).toBe('dms.sources.fieldError.host');
		expect(fieldErrorKey('config.host', 'ip_literal_not_allowed')).toBe('dms.sources.fieldError.hostIp');
		expect(fieldErrorKey('config.host', 'target_not_allowed')).toBe('dms.sources.fieldError.hostInternal');
		expect(fieldErrorKey('config.port', 'port_not_allowed')).toBe('dms.sources.fieldError.portNotAllowed');
		expect(sourceErrorKey('target_not_allowed')).toBe('dms.sources.error.target_not_allowed');
		expect(sourceErrorKey('imap_response_too_large')).toBe('dms.sources.error.imap_response_too_large');
	});
});
