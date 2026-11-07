import type { IncomingMessage, ServerResponse } from 'node:http';
import { randomUUID } from 'node:crypto';

/**
 * In-memory mock of the lab-hub auth API (contracts/openapi.yaml, WP-K1/K2). Test double only: it does not verify
 * WebAuthn signatures, it checks challenge ids, the setup token, invitations, the session cookie and the CSRF header.
 * Fixtures are synthetic. State lives in this object, so each test run starts from `createMockApi()`.
 */

export const MOCK_SETUP_TOKEN = 'mock-setup-token';
export const MOCK_INVITE_TOKEN = 'mock-invite-token';
export const MOCK_RECOVERY_CODE = 'AAAA-BBBB-CCCC';

type Json = Record<string, unknown>;

interface MockUser {
	id: string;
	handle: string;
	display_name: string;
	is_operator: boolean;
	tenantId: string;
	tenantName: string;
	role: string;
	credentialIds: string[];
	recoveryCodes: Set<string>;
}

interface MockSession {
	userId: string;
	kind: 'normal' | 'recovery';
	csrf: string;
}

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
	let challenges = new Map<string, { purpose: string; handle?: string; displayName?: string }>();
	let inviteUsed = false;

	function reset() {
		users = [];
		sessions = new Map();
		challenges = new Map();
		inviteUsed = false;
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

	async function readBody(req: IncomingMessage): Promise<Json> {
		const chunks: Buffer[] = [];
		for await (const chunk of req) chunks.push(chunk as Buffer);
		if (chunks.length === 0) return {};
		try {
			return JSON.parse(Buffer.concat(chunks).toString('utf8')) as Json;
		} catch {
			throw new ProblemError(400, 'bad_request', 'Ungueltige Anfrage');
		}
	}

	function sessionResponse(user: MockUser, session: MockSession, token: string) {
		return {
			user: { id: user.id, handle: user.handle, display_name: user.display_name, is_operator: user.is_operator },
			memberships: [{ tenant_id: user.tenantId, name: user.tenantName, role: user.role }],
			kind: session.kind,
			expires_at: new Date(Date.now() + 30 * 86400_000).toISOString(),
			csrf_token: session.csrf,
			_token: token
		};
	}

	function startSession(res: ServerResponse, status: number, user: MockUser, kind: 'normal' | 'recovery') {
		const token = randomUUID();
		const session: MockSession = { userId: user.id, kind, csrf: randomUUID() };
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

	function passkeyOptions(purpose: string, handle?: string, displayName?: string) {
		const challengeId = randomUUID();
		challenges.set(challengeId, { purpose, handle, displayName });
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

	function newUser(handle: string, displayName: string, tenantName: string, role: string, operator: boolean): MockUser {
		if (users.some((u) => u.handle === handle)) throw new ProblemError(409, 'handle_taken', 'Kennung vergeben');
		const user: MockUser = {
			id: randomUUID(),
			handle,
			display_name: displayName,
			is_operator: operator,
			tenantId: randomUUID(),
			tenantName,
			role,
			credentialIds: [],
			recoveryCodes: new Set([MOCK_RECOVERY_CODE])
		};
		users.push(user);
		return user;
	}

	async function route(req: IncomingMessage, res: ServerResponse, path: string) {
		const method = req.method ?? 'GET';
		const write = method !== 'GET' && method !== 'HEAD';
		const body = write ? await readBody(req) : {};

		if (method === 'GET' && path === '/api/version') return send(res, 200, { server: 'mock', api: '1', schema: null });

		if (method === 'POST' && path === '/api/v1/auth/bootstrap/options') {
			if (users.length > 0) throw new ProblemError(404, 'not_found', 'Nicht gefunden');
			if (body.setup_token !== MOCK_SETUP_TOKEN) throw new ProblemError(403, 'setup_token_invalid', 'Setup-Token ungueltig');
			return send(res, 200, passkeyOptions('bootstrap', String(body.handle), String(body.display_name)));
		}
		if (method === 'POST' && path === '/api/v1/auth/bootstrap/verify') {
			const { entry, credentialId } = takeChallenge(body, 'bootstrap');
			if (users.length > 0) throw new ProblemError(409, 'conflict', 'Bereits eingerichtet');
			const user = newUser(entry.handle ?? 'owner', entry.displayName ?? 'owner', 'Hauptmandant', 'owner', true);
			user.credentialIds.push(credentialId);
			return startSession(res, 201, user, 'normal');
		}
		if (method === 'POST' && path === '/api/v1/auth/register/options') {
			if (body.invite_token !== MOCK_INVITE_TOKEN || inviteUsed) {
				throw new ProblemError(410, 'invitation_invalid', 'Einladung ungueltig oder abgelaufen');
			}
			if (users.some((u) => u.handle === body.handle)) throw new ProblemError(409, 'handle_taken', 'Kennung vergeben');
			return send(res, 200, passkeyOptions('register', String(body.handle), String(body.display_name)));
		}
		if (method === 'POST' && path === '/api/v1/auth/register/verify') {
			const { entry, credentialId } = takeChallenge(body, 'register');
			if (inviteUsed) throw new ProblemError(410, 'invitation_invalid', 'Einladung ungueltig oder abgelaufen');
			inviteUsed = true;
			const user = newUser(entry.handle ?? 'user', entry.displayName ?? 'user', 'Hauptmandant', 'member', false);
			user.credentialIds.push(credentialId);
			return startSession(res, 201, user, 'normal');
		}
		if (method === 'POST' && path === '/api/v1/auth/login/options') return send(res, 200, passkeyOptions('login'));
		if (method === 'POST' && path === '/api/v1/auth/login/verify') {
			const { credentialId } = takeChallenge(body, 'login');
			const user = users.find((u) => u.credentialIds.includes(credentialId));
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
			user.credentialIds.push(credentialId);
			session.kind = 'normal';
			return send(res, 201, {
				id: randomUUID(),
				name: String(body.name ?? 'Passkey'),
				created_at: new Date().toISOString(),
				last_used_at: null,
				backed_up: false
			});
		}

		if (method === 'GET' && path === '/api/v1/tenants') {
			const { user } = requireSession(req, false);
			return send(res, 200, { items: [{ id: user.tenantId, name: user.tenantName, role: user.role }] });
		}

		throw new ProblemError(404, 'not_found', 'Nicht gefunden');
	}

	return {
		reset,
		async handle(req, res) {
			const path = (req.url ?? '').split('?')[0];
			if (!PATH.test(path)) return false;
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
