import type { DmsSource, DmsSourceInput } from '#lib/api/client';

/** Form model of a source (WP-F5b). Numbers stay strings while typing; `mailConfig`/`folderConfig` convert and drop empty optional fields. */
export interface MailDraft {
	host: string;
	port: string;
	username: string;
	/** Write only: never filled from the backend. On edit an empty value keeps the stored password. */
	password: string;
	mailbox: string;
	processed_mailbox: string;
	interval_seconds: string;
	sender_contains: string;
	subject_contains: string;
	include_body: boolean;
	max_per_run: string;
}
export interface FolderDraft {
	path: string;
	interval_seconds: string;
	stable_seconds: string;
}
export type SourceKind = DmsSource['kind'];

export const emptyMail = (): MailDraft => ({
	host: '',
	port: '993',
	username: '',
	password: '',
	mailbox: 'INBOX',
	processed_mailbox: '',
	interval_seconds: '120',
	sender_contains: '',
	subject_contains: '',
	include_body: false,
	max_per_run: '50'
});
export const emptyFolder = (): FolderDraft => ({ path: '', interval_seconds: '60', stable_seconds: '10' });

const str = (v: unknown): string => (typeof v === 'string' ? v : typeof v === 'number' ? String(v) : '');

export function mailFromSource(source: DmsSource): MailDraft {
	const c = source.config as Record<string, unknown>;
	return {
		host: str(c.host),
		port: str(c.port) || '993',
		username: str(c.username),
		password: '',
		mailbox: str(c.mailbox) || 'INBOX',
		processed_mailbox: str(c.processed_mailbox),
		interval_seconds: str(c.interval_seconds) || '120',
		sender_contains: str(c.sender_contains),
		subject_contains: str(c.subject_contains),
		include_body: c.include_body === true,
		max_per_run: str(c.max_per_run) || '50'
	};
}
export function folderFromSource(source: DmsSource): FolderDraft {
	const c = source.config as Record<string, unknown>;
	return { path: str(c.path), interval_seconds: str(c.interval_seconds) || '60', stable_seconds: str(c.stable_seconds) || '10' };
}

/** Number inputs bound with `bind:value` hand over a number (or null when empty) at runtime, so accept both. */
const int = (v: string | number | null) => {
	const text = String(v ?? '').trim();
	return /^-?\d+$/.test(text) ? Number(text) : Number.NaN;
};
const inRange = (v: string | number | null, min: number, max: number) => {
	const n = int(v);
	return n >= min && n <= max;
};

/** Problem keys (not texts) of a draft; empty means it can be sent. The backend validates again and has the last word. */
export function validateMail(draft: MailDraft, name: string, editing: boolean): string[] {
	const problems: string[] = [];
	if (!name.trim()) problems.push('nameRequired');
	if (!draft.host.trim()) problems.push('hostRequired');
	else if (!/^[A-Za-z0-9]([A-Za-z0-9.:-]*[A-Za-z0-9])?$/.test(draft.host.trim())) problems.push('hostInvalid');
	if (!inRange(draft.port, 1, 65535)) problems.push('portInvalid');
	if (!draft.username.trim()) problems.push('usernameRequired');
	if (!editing && !draft.password) problems.push('passwordRequired');
	if (!inRange(draft.interval_seconds, 30, 86400)) problems.push('mailIntervalInvalid');
	if (!inRange(draft.max_per_run, 1, 200)) problems.push('maxInvalid');
	for (const value of [draft.mailbox, draft.processed_mailbox, draft.sender_contains, draft.subject_contains]) {
		if ([...value].some((ch) => ch.charCodeAt(0) < 32 || ch.charCodeAt(0) > 126)) {
			problems.push('asciiOnly');
			break;
		}
	}
	return problems;
}
export function validateFolder(draft: FolderDraft, name: string): string[] {
	const problems: string[] = [];
	if (!name.trim()) problems.push('nameRequired');
	const path = draft.path.trim();
	if (!path) problems.push('pathRequired');
	else if (!/^[A-Za-z0-9_. -]+(\/[A-Za-z0-9_. -]+)*$/.test(path) || path.split('/').some((s) => s === '.' || s === '..')) problems.push('pathInvalid');
	if (!inRange(draft.interval_seconds, 10, 86400)) problems.push('folderIntervalInvalid');
	if (!inRange(draft.stable_seconds, 0, 3600)) problems.push('stableInvalid');
	return problems;
}

export function mailConfig(draft: MailDraft): Record<string, unknown> {
	const config: Record<string, unknown> = {
		host: draft.host.trim().toLowerCase(),
		port: int(draft.port),
		username: draft.username.trim(),
		mailbox: draft.mailbox.trim() || 'INBOX',
		interval_seconds: int(draft.interval_seconds),
		include_body: draft.include_body,
		max_per_run: int(draft.max_per_run)
	};
	if (draft.processed_mailbox.trim()) config.processed_mailbox = draft.processed_mailbox.trim();
	if (draft.sender_contains.trim()) config.sender_contains = draft.sender_contains.trim();
	if (draft.subject_contains.trim()) config.subject_contains = draft.subject_contains.trim();
	return config;
}
export function folderConfig(draft: FolderDraft): Record<string, unknown> {
	return { path: draft.path.trim(), interval_seconds: int(draft.interval_seconds), stable_seconds: int(draft.stable_seconds) };
}

export function createInput(kind: SourceKind, name: string, draft: MailDraft | FolderDraft): DmsSourceInput {
	if (kind === 'mail') {
		const mail = draft as MailDraft;
		return { kind, name: name.trim(), config: mailConfig(mail), password: mail.password, enabled: true };
	}
	return { kind, name: name.trim(), config: folderConfig(draft as FolderDraft), enabled: true };
}

/** Texts for the error codes a source can report (`last_error`, test result). Literal keys keep the i18n tests honest. */
export const sourceErrorKeys: Record<string, string> = {
	imap_connect_failed: 'dms.sources.error.imap_connect_failed',
	imap_tls_failed: 'dms.sources.error.imap_tls_failed',
	imap_auth_failed: 'dms.sources.error.imap_auth_failed',
	imap_mailbox_not_found: 'dms.sources.error.imap_mailbox_not_found',
	imap_timeout: 'dms.sources.error.imap_timeout',
	imap_response_too_large: 'dms.sources.error.imap_response_too_large',
	target_not_allowed: 'dms.sources.error.target_not_allowed',
	secret_key_missing: 'dms.sources.error.secret_key_missing',
	secret_unreadable: 'dms.sources.error.secret_unreadable',
	secret_missing: 'dms.sources.error.secret_missing',
	folder_not_found: 'dms.sources.error.folder_not_found',
	folder_root_missing: 'dms.sources.error.folder_root_missing',
	storage_quota_exceeded: 'dms.sources.error.storage_quota_exceeded',
	ingest_failed: 'dms.sources.error.ingest_failed',
	payload_invalid: 'dms.sources.error.payload_invalid',
	poll_failed: 'dms.sources.error.poll_failed',
	scan_failed: 'dms.sources.error.scan_failed'
};
export const sourceErrorKey = (code: string): string => sourceErrorKeys[code] ?? 'dms.sources.error.unknown';

/** Field errors of a 422 on create/update: backend field name (`config.host`, `password`) + code to a text key. */
export function fieldErrorKey(field: string, code: string): string {
	if (field === 'password' && code === 'secret_key_missing') return 'dms.sources.error.secret_key_missing';
	if (field === 'config.host' && code === 'ip_literal_not_allowed') return 'dms.sources.fieldError.hostIp';
	if (field === 'config.host' && code === 'target_not_allowed') return 'dms.sources.fieldError.hostInternal';
	if (field === 'config.port' && code === 'port_not_allowed') return 'dms.sources.fieldError.portNotAllowed';
	if (field === 'config.host') return 'dms.sources.fieldError.host';
	if (field.startsWith('config.') && code === 'unknown') return 'dms.sources.fieldError.unknown';
	return 'dms.sources.fieldError.generic';
}

/** Counter names of `last_stats` per kind, in display order. */
export const statKeys: Record<SourceKind, { key: string; label: string }[]> = {
	mail: [
		{ key: 'messages', label: 'dms.sources.stat.messages' },
		{ key: 'ingested', label: 'dms.sources.stat.ingested' },
		{ key: 'duplicates', label: 'dms.sources.stat.duplicates' },
		{ key: 'skipped', label: 'dms.sources.stat.skipped' },
		{ key: 'failed', label: 'dms.sources.stat.failed' }
	],
	folder: [
		{ key: 'files', label: 'dms.sources.stat.files' },
		{ key: 'ingested', label: 'dms.sources.stat.ingested' },
		{ key: 'duplicates', label: 'dms.sources.stat.duplicates' },
		{ key: 'waiting', label: 'dms.sources.stat.waiting' },
		{ key: 'failed', label: 'dms.sources.stat.failed' }
	]
};
