import { randomBytes, randomUUID } from 'node:crypto';
import type { DmsContext, TenantData } from './dms.ts';

/**
 * Mock of the WP-D4 routes (contracts/openapi.yaml): DMS sources (`dms/sources`, run, test) and personal API tokens
 * (`auth/api-tokens`). Test double with synthetic data only; the share endpoint itself is not mocked (real E2E covers it).
 *
 * Behaviour that tests rely on (the outcome of a test or run depends on the configuration):
 * - mail: host containing `tls-fail` -> `imap_tls_failed`, host containing `slow` -> `imap_timeout`, user `wrong` ->
 *   `imap_auth_failed`, mailbox `MISSING` -> `imap_mailbox_not_found`; anything else works (3 unread messages).
 * - folder: a path containing `missing` -> `folder_not_found` after a run; anything else works. Folders cannot be tested (409).
 * - create: host `blocked.example.org` is "not allowed by the operator" (422 `config.host`), password `no-key` answers 422
 *   `secret_key_missing` on field `password`, a duplicate name 409. The password is never returned (only `has_secret`).
 * - "run" executes the run at once (the real backend schedules it) and answers 202 with the source.
 */

interface Source {
	id: string;
	kind: 'mail' | 'folder';
	name: string;
	config: Record<string, unknown>;
	hasSecret: boolean;
	enabled: boolean;
	runs: number;
	last_run_at: string | null;
	last_status: 'ok' | 'error' | null;
	last_error: string | null;
	last_stats: Record<string, number> | null;
	created_at: string;
	updated_at: string;
}

const sourcesOf = new WeakMap<TenantData, Source[]>();
const MAIL_KEYS = ['host', 'port', 'username', 'mailbox', 'processed_mailbox', 'interval_seconds', 'include_body', 'sender_contains', 'subject_contains', 'max_per_run'];
const FOLDER_KEYS = ['path', 'interval_seconds', 'stable_seconds'];

function publicSource(s: Source) {
	return {
		id: s.id,
		kind: s.kind,
		name: s.name,
		config: s.config,
		has_secret: s.hasSecret,
		enabled: s.enabled,
		runs: s.runs,
		last_run_at: s.last_run_at,
		last_status: s.last_status,
		last_error: s.last_error,
		last_stats: s.last_stats,
		created_at: s.created_at,
		updated_at: s.updated_at
	};
}

/** Error code a mail source or a folder source runs into with its current configuration, or null. */
function failure(s: Source): string | null {
	const c = s.config;
	if (s.kind === 'mail') {
		const host = String(c.host);
		if (host.includes('tls-fail')) return 'imap_tls_failed';
		if (host.includes('slow')) return 'imap_timeout';
		if (c.username === 'wrong') return 'imap_auth_failed';
		if (c.mailbox === 'MISSING') return 'imap_mailbox_not_found';
		return null;
	}
	return String(c.path).includes('missing') ? 'folder_not_found' : null;
}

export function handleSources(d: TenantData, ctx: DmsContext): boolean {
	const [, resource, id, action] = ctx.parts;
	if (resource !== 'sources') return false;
	const m = ctx.method;
	const list = sourcesOf.get(d) ?? [];
	sourcesOf.set(d, list);
	const need = (permission: string) => {
		if (!ctx.permissions.includes(permission)) ctx.fail(403, 'forbidden', 'Keine Berechtigung');
	};
	const validation = (field: string, code: string) => {
		ctx.send(422, { type: 'about:blank', title: 'Eingabe ungueltig', status: 422, code: 'validation_failed', request_id: randomUUID(), errors: [{ field, code }] });
		return true;
	};
	const find = () => {
		const s = list.find((x) => x.id === id);
		if (!s) ctx.fail(404, 'not_found', 'Nicht gefunden');
		return s!;
	};

	/** Strict config check like the backend; returns a field error or null. */
	const checkConfig = (kind: string, config: unknown): { field: string; code: string } | null => {
		if (typeof config !== 'object' || config === null || Array.isArray(config)) return { field: 'config', code: 'invalid' };
		const c = config as Record<string, unknown>;
		const allowed = kind === 'mail' ? MAIL_KEYS : FOLDER_KEYS;
		for (const key of Object.keys(c)) if (!allowed.includes(key)) return { field: `config.${key}`, code: 'unknown' };
		if (kind === 'mail') {
			const host = c.host;
			if (typeof host !== 'string' || !/^[A-Za-z0-9]([A-Za-z0-9.:-]*[A-Za-z0-9])?$/.test(host) || host.toLowerCase() === 'blocked.example.org') return { field: 'config.host', code: 'invalid' };
			if (typeof c.username !== 'string' || !c.username) return { field: 'config.username', code: 'required' };
			if (c.port !== undefined && (!Number.isInteger(c.port) || (c.port as number) < 1 || (c.port as number) > 65535)) return { field: 'config.port', code: 'invalid' };
		} else if (typeof c.path !== 'string' || !c.path || c.path.startsWith('/') || c.path.split('/').some((s) => s === '..' || s === '.')) {
			return { field: 'config.path', code: 'invalid' };
		}
		return null;
	};
	const normalize = (kind: string, c: Record<string, unknown>): Record<string, unknown> =>
		kind === 'mail'
			? { port: 993, mailbox: 'INBOX', interval_seconds: 120, include_body: false, max_per_run: 50, ...c, host: String(c.host).toLowerCase() }
			: { interval_seconds: 60, stable_seconds: 10, ...c };

	if (!id && m === 'GET') {
		need('dms.source.read');
		return ctx.send(200, { items: list.map(publicSource) }), true;
	}
	if (!id && m === 'POST') {
		need('dms.source.manage');
		const body = ctx.json;
		if (body.kind !== 'mail' && body.kind !== 'folder') return validation('kind', 'invalid');
		if (typeof body.name !== 'string' || !body.name.trim() || body.name.length > 100) return validation('name', 'invalid');
		const bad = checkConfig(body.kind, body.config);
		if (bad) return validation(bad.field, bad.code);
		if (body.kind === 'mail') {
			if (typeof body.password !== 'string' || !body.password) return validation('password', 'required');
			if (body.password === 'no-key') return validation('password', 'secret_key_missing');
		} else if ('password' in body) return validation('password', 'not_allowed');
		if (list.length >= 50) ctx.fail(409, 'conflict', 'Zu viele Quellen');
		if (list.some((x) => x.name.toLowerCase() === (body.name as string).trim().toLowerCase())) ctx.fail(409, 'conflict', 'Name bereits vergeben');
		const now = new Date().toISOString();
		const source: Source = {
			id: randomUUID(),
			kind: body.kind,
			name: body.name.trim(),
			config: normalize(body.kind, body.config as Record<string, unknown>),
			hasSecret: body.kind === 'mail',
			enabled: body.enabled !== false,
			runs: 0,
			last_run_at: null,
			last_status: null,
			last_error: null,
			last_stats: null,
			created_at: now,
			updated_at: now
		};
		list.push(source);
		return ctx.send(201, publicSource(source)), true;
	}
	if (id && !action) {
		if (m === 'GET') return need('dms.source.read'), ctx.send(200, publicSource(find())), true;
		if (m === 'PATCH') {
			need('dms.source.manage');
			const s = find();
			const body = ctx.json;
			if ('kind' in body) return validation('kind', 'immutable');
			if ('name' in body) {
				if (typeof body.name !== 'string' || !body.name.trim() || body.name.length > 100) return validation('name', 'invalid');
				if (list.some((x) => x !== s && x.name.toLowerCase() === (body.name as string).trim().toLowerCase())) ctx.fail(409, 'conflict', 'Name bereits vergeben');
			}
			if ('config' in body) {
				const bad = checkConfig(s.kind, body.config);
				if (bad) return validation(bad.field, bad.code);
			}
			if ('password' in body) {
				if (s.kind !== 'mail' || typeof body.password !== 'string' || !body.password) return validation('password', 'invalid');
				if (body.password === 'no-key') return validation('password', 'secret_key_missing');
				s.hasSecret = true;
			}
			if ('enabled' in body && typeof body.enabled !== 'boolean') return validation('enabled', 'invalid');
			if (typeof body.name === 'string') s.name = body.name.trim();
			if ('config' in body) s.config = normalize(s.kind, body.config as Record<string, unknown>);
			if (typeof body.enabled === 'boolean') s.enabled = body.enabled;
			s.updated_at = new Date().toISOString();
			return ctx.send(200, publicSource(s)), true;
		}
		if (m === 'DELETE') {
			need('dms.source.manage');
			const s = find();
			list.splice(list.indexOf(s), 1);
			return ctx.send(204), true;
		}
	}
	if (id && action === 'run' && m === 'POST') {
		need('dms.source.manage');
		const s = find();
		const code = failure(s);
		s.runs += 1;
		s.last_run_at = new Date().toISOString();
		s.last_status = code ? 'error' : 'ok';
		s.last_error = code;
		s.last_stats = code ? null : s.kind === 'mail' ? { messages: 3, ingested: 2, duplicates: 1, skipped: 0, failed: 0 } : { files: 1, ingested: 1, duplicates: 0, waiting: 0, failed: 0 };
		return ctx.send(202, publicSource(s)), true;
	}
	if (id && action === 'test' && m === 'POST') {
		need('dms.source.manage');
		const s = find();
		if (s.kind !== 'mail') ctx.fail(409, 'conflict', 'Test nicht unterstuetzt');
		const code = failure(s);
		return ctx.send(200, code ? { ok: false, error: code } : { ok: true, unseen: 3 }), true;
	}
	return false;
}

// ---------------------------------------------------------------- personal API tokens (core route, per user)

interface Token {
	id: string;
	name: string;
	scopes: string[];
	expires_at: string;
	created_at: string;
	last_used_at: string | null;
	revoked_at: string | null;
}

export function createTokenStore() {
	let tokens = new Map<string, Token[]>();
	return {
		reset: () => {
			tokens = new Map();
		},
		/** `parts` is the path below `/api/v1/auth/api-tokens`. Returns `[status, body]` or an error as `[status, code, title]`. */
		handle(method: string, parts: string[], body: Record<string, unknown>, userId: string): { status: number; body?: unknown } | { status: number; code: string; title: string } {
			const mine = tokens.get(userId) ?? [];
			tokens.set(userId, mine);
			if (parts.length === 0 && method === 'GET') return { status: 200, body: { items: mine } };
			if (parts.length === 0 && method === 'POST') {
				const days = body.expires_in_days === undefined ? 365 : body.expires_in_days;
				const scopes = body.scopes;
				const bad =
					typeof body.name !== 'string' || !body.name.trim() || body.name.length > 80 || !Array.isArray(scopes) || scopes.length === 0 || scopes.some((s) => s !== 'dms.upload') || !Number.isInteger(days) || (days as number) < 1 || (days as number) > 730;
				if (bad) return { status: 422, code: 'validation_failed', title: 'Eingabe ungueltig' };
				const now = new Date();
				const token: Token = {
					id: randomUUID(),
					name: (body.name as string).trim(),
					scopes: scopes as string[],
					expires_at: new Date(now.getTime() + (days as number) * 86400_000).toISOString(),
					created_at: now.toISOString(),
					last_used_at: null,
					revoked_at: null
				};
				mine.unshift(token);
				return { status: 201, body: { ...token, token: `lhp_${randomBytes(32).toString('base64url')}` } };
			}
			if (parts.length === 1 && method === 'DELETE') {
				const token = mine.find((x) => x.id === parts[0]);
				if (!token) return { status: 404, code: 'not_found', title: 'Nicht gefunden' };
				token.revoked_at ??= new Date().toISOString();
				return { status: 204 };
			}
			return { status: 404, code: 'not_found', title: 'Nicht gefunden' };
		}
	};
}
