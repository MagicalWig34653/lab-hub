import type { IncomingMessage, ServerResponse } from 'node:http';
import { randomUUID } from 'node:crypto';
import { createDmsMock } from './dms.ts';

/**
 * In-memory mock of the lab-hub auth API (contracts/openapi.yaml, WP-K1/K2). Test double only: it does not verify
 * WebAuthn signatures, it checks challenge ids, the setup token, invitations, the session cookie and the CSRF header.
 * Fixtures are synthetic. State lives in this object, so each test run starts from `createMockApi()`.
 */

export const MOCK_SETUP_TOKEN = 'mock-setup-token';
export const MOCK_INVITE_TOKEN = 'mock-invite-token';
export const MOCK_RECOVERY_CODE = 'AAAA-BBBB-CCCC';

type Json = Record<string, unknown>;

interface MockPasskey {
	id: string;
	credentialId: string;
	name: string;
	createdAt: string;
}

interface MockUser {
	id: string;
	handle: string;
	display_name: string;
	is_operator: boolean;
	passkeys: MockPasskey[];
	recoveryCodes: Set<string>;
}

interface MockSession {
	id: string;
	userId: string;
	kind: 'normal' | 'recovery';
	csrf: string;
	createdAt: string;
}

interface MockTenant {
	id: string;
	name: string;
	modules: Set<string>;
	roles: Map<string, string>;
}

interface MockInvitation {
	tenantId: string | null;
	role: string;
	used: boolean;
}

/** Module catalogue of the mock installation (the real one is `GET /api/v1/modules`). Navigation mirrors DMSModule. */
const MOCK_MODULES = [{ key: 'dms', requires: [] as string[], enhances: [] as string[], installed: true }];
const MOCK_NAVIGATION = [{ module: 'dms', key: 'dms', label_key: 'nav.dms', path: '/dms' }];
const ROLES = ['owner', 'accountant', 'member', 'tax_advisor', 'customer_viewer'];
const DMS_READ = [
	'dms.document.read',
	'dms.document.create',
	'dms.document.update',
	'dms.document.download_original',
	'dms.suggestion.read',
	'dms.suggestion.decide',
	'dms.rule.read',
	'contact.contact.read'
];
const OWNER_PERMISSIONS = [
	...DMS_READ,
	'dms.document.trash',
	'dms.document.purge',
	'dms.document.retention',
	'dms.rule.manage',
	'dms.master.manage',
	'dms.tag.manage',
	'dms.integrity.run',
	'dms.export.run',
	'tenant.tenant.read',
	'tenant.member.read',
	'tenant.member.invite',
	'tenant.member.manage',
	'tenant.module.read',
	'tenant.module.manage'
];
const MEMBER_PERMISSIONS = ['tenant.tenant.read', 'tenant.member.read', 'tenant.module.read', ...DMS_READ];
/** Reader without download right: sees metadata, cannot fetch the original (AK: original download only with permission). */
const VIEWER_PERMISSIONS = ['tenant.tenant.read', 'tenant.module.read', 'dms.document.read'];

export interface MockApi {
	handle(req: IncomingMessage, res: ServerResponse): Promise<boolean>;
	reset(): void;
}

class ProblemError extends Error {
	readonly status: number;
	readonly code: string;
	readonly title: string;

	constructor(status: number, code: string, title: string) {
		super(code);
		this.status = status;
		this.code = code;
		this.title = title;
	}
}

const PATH = /^\/api\//;

export function createMockApi(): MockApi {
	let users: MockUser[] = [];
	let sessions = new Map<string, MockSession>();
	let challenges = new Map<string, { purpose: string; handle?: string; displayName?: string; inviteToken?: string }>();
	let tenants: MockTenant[] = [];
	let invitations = new Map<string, MockInvitation>();
	const dms = createDmsMock();

	function reset() {
		users = [];
		sessions = new Map();
		challenges = new Map();
		tenants = [];
		dms.reset();
		invitations = new Map([[MOCK_INVITE_TOKEN, { tenantId: null, role: 'member', used: false }]]);
	}
	reset();

	/** Two synthetic tenants exist as soon as the first user does: the main tenant and a second one for tenant switching. */
	function ensureTenants(): [MockTenant, MockTenant] {
		if (tenants.length === 0) {
			tenants = [
				{ id: randomUUID(), name: 'Hauptmandant', modules: new Set(), roles: new Map() },
				{ id: randomUUID(), name: 'Zweitmandant', modules: new Set(), roles: new Map() }
			];
		}
		return [tenants[0], tenants[1]];
	}

	function membershipsOf(user: MockUser) {
		return tenants
			.filter((t) => t.roles.has(user.id))
			.map((t) => ({ tenant_id: t.id, name: t.name, role: t.roles.get(user.id)! }));
	}

	function tenantFor(user: MockUser, id: string): MockTenant {
		const tenant = tenants.find((t) => t.id === id);
		if (!tenant || !tenant.roles.has(user.id)) throw new ProblemError(404, 'not_found', 'Nicht gefunden');
		return tenant;
	}

	function permissionsOf(role: string): string[] {
		return role === 'owner' ? OWNER_PERMISSIONS : role === 'customer_viewer' ? VIEWER_PERMISSIONS : MEMBER_PERMISSIONS;
	}

	function require(user: MockUser, tenant: MockTenant, permission: string) {
		if (!permissionsOf(tenant.roles.get(user.id)!).includes(permission)) {
			throw new ProblemError(403, 'forbidden', 'Keine Berechtigung');
		}
	}

	function moduleState(tenant: MockTenant, key: string) {
		const catalogue = MOCK_MODULES.find((m) => m.key === key)!;
		const enabled = tenant.modules.has(key);
		return { key, requires: catalogue.requires, enhances: catalogue.enhances, installed: catalogue.installed, enabled, effective: catalogue.installed && enabled };
	}

	function send(res: ServerResponse, status: number, body?: unknown, headers: Record<string, string> = {}) {
		const payload = body === undefined ? '' : JSON.stringify(body);
		res.writeHead(status, {
			'content-type': status >= 400 ? 'application/problem+json' : 'application/json',
			'x-request-id': randomUUID(),
			...headers
		});
		res.end(payload);
	}

	function problem(res: ServerResponse, error: ProblemError) {
		send(res, error.status, {
			type: `https://hub.example.org/problems/${error.code}`,
			title: error.title,
			status: error.status,
			code: error.code,
			request_id: randomUUID()
		});
	}

	async function readRaw(req: IncomingMessage): Promise<Buffer> {
		const chunks: Buffer[] = [];
		for await (const chunk of req) chunks.push(chunk as Buffer);
		return Buffer.concat(chunks);
	}

	function parseBody(raw: Buffer): Json {
		if (raw.length === 0) return {};
		try {
			return JSON.parse(raw.toString('utf8')) as Json;
		} catch {
			throw new ProblemError(400, 'bad_request', 'Ungueltige Anfrage');
		}
	}

	function sessionResponse(user: MockUser, session: MockSession, token: string) {
		return {
			user: { id: user.id, handle: user.handle, display_name: user.display_name, is_operator: user.is_operator },
			memberships: membershipsOf(user),
			kind: session.kind,
			expires_at: new Date(Date.now() + 30 * 86400_000).toISOString(),
			csrf_token: session.csrf,
			_token: token
		};
	}

	function startSession(res: ServerResponse, status: number, user: MockUser, kind: 'normal' | 'recovery') {
		const token = randomUUID();
		const session: MockSession = { id: randomUUID(), userId: user.id, kind, csrf: randomUUID(), createdAt: new Date().toISOString() };
		sessions.set(token, session);
		const { _token, ...body } = sessionResponse(user, session, token);
		void _token;
		send(res, status, body, { 'set-cookie': `lh_session=${token}; HttpOnly; SameSite=Lax; Path=/` });
	}

	function cookieToken(req: IncomingMessage): string | null {
		const header = req.headers.cookie ?? '';
		const match = /(?:^|;\s*)lh_session=([^;]+)/.exec(header);
		return match ? match[1] : null;
	}

	function requireSession(req: IncomingMessage, write: boolean) {
		const token = cookieToken(req);
		const session = token ? sessions.get(token) : undefined;
		if (!token || !session) throw new ProblemError(401, 'unauthorized', 'Nicht angemeldet');
		if (write && req.headers['x-csrf-token'] !== session.csrf) {
			throw new ProblemError(403, 'csrf_invalid', 'CSRF-Pruefung fehlgeschlagen');
		}
		const user = users.find((u) => u.id === session.userId)!;
		return { token, session, user };
	}

	function passkeyOptions(purpose: string, handle?: string, displayName?: string, inviteToken?: string) {
		const challengeId = randomUUID();
		challenges.set(challengeId, { purpose, handle, displayName, inviteToken });
		const challenge = Buffer.from(randomUUID()).toString('base64url');
		const publicKey =
			purpose === 'login'
				? { challenge, rpId: undefined, timeout: 60000, userVerification: 'required' }
				: {
						challenge,
						rp: { name: 'lab-hub' },
						user: {
							id: Buffer.from(randomUUID()).toString('base64url'),
							name: handle ?? 'user',
							displayName: displayName ?? handle ?? 'user'
						},
						pubKeyCredParams: [
							{ type: 'public-key', alg: -7 },
							{ type: 'public-key', alg: -257 }
						],
						authenticatorSelection: { residentKey: 'required', userVerification: 'required' },
						timeout: 60000,
						attestation: 'none'
					};
		return { challenge_id: challengeId, public_key: publicKey };
	}

	function takeChallenge(body: Json, purpose: string) {
		const id = String(body.challenge_id ?? '');
		const entry = challenges.get(id);
		const credential = body.credential as { id?: unknown } | undefined;
		if (!entry || entry.purpose !== purpose || typeof credential?.id !== 'string') {
			throw new ProblemError(400, 'passkey_invalid', 'Passkey ungueltig');
		}
		challenges.delete(id);
		return { entry, credentialId: credential.id };
	}

	function newUser(handle: string, displayName: string, operator: boolean): MockUser {
		if (users.some((u) => u.handle === handle)) throw new ProblemError(409, 'handle_taken', 'Kennung vergeben');
		const user: MockUser = {
			id: randomUUID(),
			handle,
			display_name: displayName,
			is_operator: operator,
			passkeys: [],
			// One preset code lets the recovery-login flow be tested; the real backend issues none until the user generates them.
			recoveryCodes: new Set([MOCK_RECOVERY_CODE])
		};
		users.push(user);
		return user;
	}

	function addPasskey(user: MockUser, credentialId: string, name: string): MockPasskey {
		const passkey = { id: randomUUID(), credentialId, name, createdAt: new Date().toISOString() };
		user.passkeys.push(passkey);
		return passkey;
	}

	function passkeyInfo(p: MockPasskey) {
		return { id: p.id, name: p.name, created_at: p.createdAt, last_used_at: null, backed_up: false };
	}

	async function route(req: IncomingMessage, res: ServerResponse, path: string) {
		const method = req.method ?? 'GET';
		const write = method !== 'GET' && method !== 'HEAD';
		const raw = write ? await readRaw(req) : Buffer.alloc(0);
		const isBinary = (req.headers['content-type'] ?? '').startsWith('application/octet-stream');
		const body = write && !isBinary ? parseBody(raw) : {};
		const query = new URL(req.url ?? '/', 'http://localhost').searchParams;

		if (method === 'GET' && path === '/api/version') return send(res, 200, { server: 'mock', api: '1', schema: null });

		if (method === 'POST' && path === '/api/v1/auth/bootstrap/options') {
			if (users.length > 0) throw new ProblemError(404, 'not_found', 'Nicht gefunden');
			if (body.setup_token !== MOCK_SETUP_TOKEN) throw new ProblemError(403, 'setup_token_invalid', 'Setup-Token ungueltig');
			return send(res, 200, passkeyOptions('bootstrap', String(body.handle), String(body.display_name)));
		}
		if (method === 'POST' && path === '/api/v1/auth/bootstrap/verify') {
			const { entry, credentialId } = takeChallenge(body, 'bootstrap');
			if (users.length > 0) throw new ProblemError(409, 'conflict', 'Bereits eingerichtet');
			const user = newUser(entry.handle ?? 'owner', entry.displayName ?? 'owner', true);
			const [main, second] = ensureTenants();
			main.roles.set(user.id, 'owner');
			second.roles.set(user.id, 'member');
			addPasskey(user, credentialId, 'Passkey');
			return startSession(res, 201, user, 'normal');
		}
		if (method === 'POST' && path === '/api/v1/auth/register/options') {
			const invitation = invitations.get(String(body.invite_token));
			if (!invitation || invitation.used) {
				throw new ProblemError(410, 'invitation_invalid', 'Einladung ungueltig oder abgelaufen');
			}
			if (users.some((u) => u.handle === body.handle)) throw new ProblemError(409, 'handle_taken', 'Kennung vergeben');
			return send(res, 200, passkeyOptions('register', String(body.handle), String(body.display_name), String(body.invite_token)));
		}
		if (method === 'POST' && path === '/api/v1/auth/register/verify') {
			const { entry, credentialId } = takeChallenge(body, 'register');
			const invitation = invitations.get(entry.inviteToken ?? '');
			if (!invitation || invitation.used) throw new ProblemError(410, 'invitation_invalid', 'Einladung ungueltig oder abgelaufen');
			invitation.used = true;
			const user = newUser(entry.handle ?? 'user', entry.displayName ?? 'user', false);
			const tenant = invitation.tenantId ? tenants.find((t) => t.id === invitation.tenantId)! : ensureTenants()[0];
			tenant.roles.set(user.id, invitation.role);
			addPasskey(user, credentialId, 'Passkey');
			return startSession(res, 201, user, 'normal');
		}
		if (method === 'POST' && path === '/api/v1/auth/login/options') return send(res, 200, passkeyOptions('login'));
		if (method === 'POST' && path === '/api/v1/auth/login/verify') {
			const { credentialId } = takeChallenge(body, 'login');
			const user = users.find((u) => u.passkeys.some((p) => p.credentialId === credentialId));
			if (!user) throw new ProblemError(401, 'login_failed', 'Anmeldung fehlgeschlagen');
			return startSession(res, 200, user, 'normal');
		}
		if (method === 'POST' && path === '/api/v1/auth/recovery/login') {
			const user = users.find((u) => u.handle === body.handle);
			if (!user || !user.recoveryCodes.delete(String(body.code))) {
				throw new ProblemError(401, 'login_failed', 'Anmeldung fehlgeschlagen');
			}
			return startSession(res, 200, user, 'recovery');
		}

		if (method === 'GET' && path === '/api/v1/auth/session') {
			const { token, session, user } = requireSession(req, false);
			const { _token, ...out } = sessionResponse(user, session, token);
			void _token;
			return send(res, 200, out);
		}
		if (method === 'POST' && path === '/api/v1/auth/logout') {
			const { token } = requireSession(req, true);
			sessions.delete(token);
			return send(res, 204, undefined, { 'set-cookie': 'lh_session=; HttpOnly; Path=/; Max-Age=0' });
		}

		if (method === 'POST' && path === '/api/v1/me/passkeys/options') {
			const { user } = requireSession(req, true);
			return send(res, 200, passkeyOptions('add', user.handle, user.display_name));
		}
		if (method === 'POST' && path === '/api/v1/me/passkeys/verify') {
			const { session, user } = requireSession(req, true);
			const { credentialId } = takeChallenge(body, 'add');
			const passkey = addPasskey(user, credentialId, String(body.name ?? 'Passkey'));
			session.kind = 'normal';
			return send(res, 201, passkeyInfo(passkey));
		}

		// Everything below is closed to emergency (recovery) sessions, like the backend (recovery_session_restricted).
		const auth = () => {
			const a = requireSession(req, write);
			if (a.session.kind === 'recovery') {
				throw new ProblemError(403, 'recovery_session_restricted', 'Nur Passkey anlegen erlaubt');
			}
			return a;
		};
		const parts = path.slice('/api/v1/'.length).split('/');

		if (method === 'POST' && path === '/api/v1/auth/logout-all') {
			const { user } = auth();
			let revoked = 0;
			for (const [token, s] of [...sessions]) {
				if (s.userId === user.id) {
					sessions.delete(token);
					revoked++;
				}
			}
			return send(res, 200, { revoked }, { 'set-cookie': 'lh_session=; HttpOnly; Path=/; Max-Age=0' });
		}
		if (method === 'GET' && path === '/api/v1/auth/sessions') {
			const { token, user } = auth();
			const items = [...sessions]
				.filter(([, s]) => s.userId === user.id)
				.map(([tk, s]) => ({
					id: s.id,
					kind: s.kind,
					created_at: s.createdAt,
					last_seen_at: s.createdAt,
					expires_at: new Date(Date.now() + 30 * 86400_000).toISOString(),
					current: tk === token
				}));
			return send(res, 200, { items });
		}
		if (method === 'DELETE' && parts[0] === 'auth' && parts[1] === 'sessions' && parts.length === 3) {
			const { user } = auth();
			const entry = [...sessions].find(([, s]) => s.id === parts[2] && s.userId === user.id);
			if (!entry) throw new ProblemError(404, 'not_found', 'Nicht gefunden');
			sessions.delete(entry[0]);
			return send(res, 204);
		}

		if (method === 'GET' && path === '/api/v1/me/recovery-codes') {
			return send(res, 200, { remaining: auth().user.recoveryCodes.size });
		}
		if (method === 'POST' && path === '/api/v1/me/recovery-codes') {
			const { user } = auth();
			const codes = Array.from({ length: 8 }, (_, i) => `MOCK-${String(i + 1).padStart(4, '0')}-${randomUUID().slice(0, 4).toUpperCase()}`);
			user.recoveryCodes = new Set(codes);
			return send(res, 201, { codes });
		}
		if (method === 'GET' && path === '/api/v1/me/passkeys') {
			return send(res, 200, { items: auth().user.passkeys.map(passkeyInfo) });
		}
		if (method === 'DELETE' && parts[0] === 'me' && parts[1] === 'passkeys' && parts.length === 3) {
			const { user } = auth();
			const index = user.passkeys.findIndex((p) => p.id === parts[2]);
			if (index < 0) throw new ProblemError(404, 'not_found', 'Nicht gefunden');
			if (user.passkeys.length === 1) throw new ProblemError(409, 'last_passkey', 'Letzter Passkey');
			user.passkeys.splice(index, 1);
			return send(res, 204);
		}

		if (method === 'GET' && path === '/api/v1/modules') {
			auth();
			return send(res, 200, { items: MOCK_MODULES });
		}
		if (method === 'GET' && path === '/api/v1/tenants') {
			const { user } = auth();
			return send(res, 200, { items: membershipsOf(user).map((m) => ({ id: m.tenant_id, name: m.name, role: m.role })) });
		}

		if (parts[0] === 'tenants' && parts.length >= 2) {
			const { user } = auth();
			const tenant = tenantFor(user, parts[1]);
			const role = tenant.roles.get(user.id)!;
			const sub = parts.slice(2).join('/');

			if (method === 'GET' && sub === '') {
				return send(res, 200, { id: tenant.id, name: tenant.name, role, permissions: permissionsOf(role) });
			}
			if (method === 'GET' && sub === 'modules') {
				require(user, tenant, 'tenant.module.read');
				return send(res, 200, {
					items: MOCK_MODULES.map((m) => moduleState(tenant, m.key)),
					navigation: MOCK_NAVIGATION.filter((n) => moduleState(tenant, n.module).effective)
				});
			}
			if (method === 'PUT' && parts[2] === 'modules' && parts.length === 4) {
				require(user, tenant, 'tenant.module.manage');
				if (!MOCK_MODULES.some((m) => m.key === parts[3])) throw new ProblemError(404, 'not_found', 'Nicht gefunden');
				if (typeof body.enabled !== 'boolean') throw new ProblemError(422, 'validation_failed', 'Eingabe ungueltig');
				if (body.enabled) tenant.modules.add(parts[3]);
				else tenant.modules.delete(parts[3]);
				return send(res, 200, moduleState(tenant, parts[3]));
			}
			if (parts[2] === 'dms' || (method === 'GET' && sub === 'contacts')) {
				if (!tenant.modules.has('dms')) throw new ProblemError(404, 'module_disabled', 'Modul nicht aktiviert');
				const ctx = {
					method,
					parts: parts.slice(2),
					query,
					headers: req.headers,
					json: body,
					raw,
					tenantId: tenant.id,
					permissions: permissionsOf(role),
					send: (status: number, payload?: unknown, headers?: Record<string, string>) => send(res, status, payload, headers),
					sendRaw: (status: number, buffer: Buffer, headers: Record<string, string>) => {
						res.writeHead(status, { 'x-request-id': randomUUID(), ...headers });
						res.end(buffer);
					},
					fail: (status: number, code: string, title: string): never => {
						throw new ProblemError(status, code, title);
					}
				};
				if (sub === 'contacts') {
					require(user, tenant, 'contact.contact.read');
					return dms.contacts(ctx);
				}
				if (dms.handle(ctx)) return;
			}
			if (method === 'GET' && sub === 'members') {
				require(user, tenant, 'tenant.member.read');
				const items = [...tenant.roles].map(([id, r]) => {
					const u = users.find((x) => x.id === id)!;
					return { user_id: id, handle: u.handle, display_name: u.display_name, role: r, created_at: new Date().toISOString() };
				});
				return send(res, 200, { items });
			}
			if (method === 'PATCH' && parts[2] === 'members' && parts.length === 4) {
				require(user, tenant, 'tenant.member.manage');
				if (!tenant.roles.has(parts[3])) throw new ProblemError(404, 'not_found', 'Nicht gefunden');
				if (!ROLES.includes(String(body.role))) throw new ProblemError(422, 'validation_failed', 'Eingabe ungueltig');
				const owners = [...tenant.roles.values()].filter((r) => r === 'owner').length;
				if (tenant.roles.get(parts[3]) === 'owner' && body.role !== 'owner' && owners === 1) {
					throw new ProblemError(409, 'last_owner', 'Letzter Inhaber');
				}
				tenant.roles.set(parts[3], String(body.role));
				return send(res, 200, { user_id: parts[3], role: body.role });
			}
			if (method === 'DELETE' && parts[2] === 'members' && parts.length === 4) {
				require(user, tenant, 'tenant.member.manage');
				if (!tenant.roles.has(parts[3])) throw new ProblemError(404, 'not_found', 'Nicht gefunden');
				const owners = [...tenant.roles.values()].filter((r) => r === 'owner').length;
				if (tenant.roles.get(parts[3]) === 'owner' && owners === 1) throw new ProblemError(409, 'last_owner', 'Letzter Inhaber');
				tenant.roles.delete(parts[3]);
				return send(res, 204);
			}
			if (method === 'POST' && sub === 'invitations') {
				require(user, tenant, 'tenant.member.invite');
				const inviteRole = typeof body.role === 'string' ? body.role : 'member';
				if (!ROLES.includes(inviteRole)) throw new ProblemError(422, 'validation_failed', 'Eingabe ungueltig');
				const token = `mock-invite-${randomUUID()}`;
				invitations.set(token, { tenantId: tenant.id, role: inviteRole, used: false });
				return send(res, 201, {
					id: randomUUID(),
					token,
					role: inviteRole,
					expires_at: new Date(Date.now() + 72 * 3600_000).toISOString(),
					link: `/invite/${token}`
				});
			}
		}

		throw new ProblemError(404, 'not_found', 'Nicht gefunden');
	}

	return {
		reset,
		async handle(req, res) {
			const path = (req.url ?? '').split('?')[0];
			if (!PATH.test(path)) return false;
			if (path === '/api/__mock/dms/seed' && req.method === 'POST') {
				// Test helper: `count` synthetic documents in the first tenant (pagination tests).
				const raw = await readRaw(req);
				const { count, ...options } = JSON.parse(raw.toString('utf8') || '{}') as { count?: number; trashed?: boolean; doc_date?: string; title?: string; tamper?: boolean };
				dms.seed(tenants[0].id, count ?? 0, options);
				send(res, 204);
				return true;
			}
			if (path === '/api/__mock/reset' && req.method === 'POST') {
				reset();
				send(res, 204);
				return true;
			}
			try {
				await route(req, res, path);
			} catch (error) {
				if (error instanceof ProblemError) problem(res, error);
				else problem(res, new ProblemError(500, 'internal_error', 'Interner Fehler'));
			}
			return true;
		}
	};
}
