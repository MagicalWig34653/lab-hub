import { ApiError, problemFromResponse } from './errors';
import type { components } from './types';

export { ApiError } from './errors';

type Schemas = components['schemas'];
export type SessionResponse = Schemas['SessionResponse'];
export type PasskeyInfo = Schemas['PasskeyInfo'];
export type PasskeyOptionsResponse = Schemas['PasskeyOptionsResponse'];
export type TenantMembership = Schemas['TenantMembership'];
export type Role = Schemas['Role'];
export type SessionInfo = Schemas['SessionInfo'];
export type Member = Schemas['Member'];
type Ops = import('./types').operations;
type JsonOf<T> = T extends { content: { 'application/json': infer B } } ? B : never;
export type TenantDetail = JsonOf<Ops['getTenant']['responses'][200]>;
export type TenantModules = JsonOf<Ops['listTenantModules']['responses'][200]>;
export type TenantModuleItem = TenantModules['items'][number];
export type NavigationEntry = TenantModules['navigation'][number];
export type TenantModuleState = JsonOf<Ops['setTenantModule']['responses'][200]>;
export type InvitationCreated = JsonOf<Ops['createInvitation']['responses'][201]>;
/** The contract declares `credential` as a free object (generated as Record<string, never>); we send the WebAuthn JSON. */
type VerifyBody = Omit<Schemas['PasskeyVerifyRequest'], 'credential'> & { credential: { [key: string]: unknown } };

const BASE = '/api/v1';
type Method = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';

let csrfToken: string | null = null;
let sessionEndedHandler: (() => void) | null = null;

/** The session response carries the CSRF token that cookie sessions must send on every write (X-CSRF-Token). */
export function setCsrfToken(token: string | null): void {
	csrfToken = token;
}

/** Called on a 401 for a data call while a session was believed valid (revoked elsewhere, expired). */
export function setSessionEndedHandler(handler: (() => void) | null): void {
	sessionEndedHandler = handler;
}

async function request<T>(method: Method, path: string, body?: unknown): Promise<T> {
	const headers: Record<string, string> = { Accept: 'application/json, application/problem+json' };
	if (body !== undefined) headers['Content-Type'] = 'application/json';
	if (method !== 'GET' && csrfToken) headers['X-CSRF-Token'] = csrfToken;
	let response: Response;
	try {
		response = await fetch(BASE + path, {
			method,
			headers,
			credentials: 'same-origin',
			body: body === undefined ? undefined : JSON.stringify(body)
		});
	} catch {
		throw new ApiError(0, 'network_error');
	}
	if (!response.ok) {
		const error = await problemFromResponse(response);
		const isAuthCall = path.startsWith('/auth/');
		if (response.status === 401 && csrfToken !== null && !isAuthCall) {
			sessionEndedHandler?.();
			throw new ApiError(401, 'session_ended', error.message, error.requestId);
		}
		throw error;
	}
	const text = await response.text();
	return (text ? JSON.parse(text) : undefined) as T;
}

/** Auth routes (WP-K1). Payload and response types come from contracts/openapi.yaml via src/lib/api/types.ts. */
export const authApi = {
	bootstrapOptions: (body: Schemas['BootstrapOptionsRequest']) =>
		request<PasskeyOptionsResponse>('POST', '/auth/bootstrap/options', body),
	bootstrapVerify: (body: VerifyBody) => request<SessionResponse>('POST', '/auth/bootstrap/verify', body),
	registerOptions: (body: Schemas['RegisterOptionsRequest']) =>
		request<PasskeyOptionsResponse>('POST', '/auth/register/options', body),
	registerVerify: (body: VerifyBody) => request<SessionResponse>('POST', '/auth/register/verify', body),
	loginOptions: () => request<PasskeyOptionsResponse>('POST', '/auth/login/options'),
	loginVerify: (body: VerifyBody) => request<SessionResponse>('POST', '/auth/login/verify', body),
	recoveryLogin: (body: Schemas['RecoveryLoginRequest']) => request<SessionResponse>('POST', '/auth/recovery/login', body),
	session: () => request<SessionResponse>('GET', '/auth/session'),
	logout: () => request<void>('POST', '/auth/logout'),
	logoutAll: () => request<{ revoked: number }>('POST', '/auth/logout-all'),
	sessions: () => request<{ items: SessionInfo[] }>('GET', '/auth/sessions'),
	revokeSession: (id: string) => request<void>('DELETE', `/auth/sessions/${id}`),
	addPasskeyOptions: () => request<PasskeyOptionsResponse>('POST', '/me/passkeys/options'),
	addPasskeyVerify: (body: VerifyBody) => request<PasskeyInfo>('POST', '/me/passkeys/verify', body)
};

/** Own account (`/me/…`): passkeys and recovery codes. Adding a passkey lives in `authApi` (also allowed in an emergency session). */
export const meApi = {
	passkeys: () => request<{ items: PasskeyInfo[] }>('GET', '/me/passkeys'),
	revokePasskey: (id: string) => request<void>('DELETE', `/me/passkeys/${id}`),
	recoveryCodeStatus: () => request<{ remaining: number }>('GET', '/me/recovery-codes'),
	generateRecoveryCodes: () => request<{ codes: string[] }>('POST', '/me/recovery-codes')
};

/** Tenant-scoped routes (WP-K2/K3): the tenant id is always part of the path. */
export const tenantApi = {
	list: () => request<{ items: TenantMembership[] }>('GET', '/tenants'),
	get: (tenant: string) => request<TenantDetail>('GET', `/tenants/${tenant}`),
	modules: (tenant: string) => request<TenantModules>('GET', `/tenants/${tenant}/modules`),
	setModule: (tenant: string, module: string, enabled: boolean) =>
		request<TenantModuleState>('PUT', `/tenants/${tenant}/modules/${module}`, { enabled }),
	members: (tenant: string) => request<{ items: Member[] }>('GET', `/tenants/${tenant}/members`),
	changeRole: (tenant: string, user: string, role: Role) =>
		request<{ user_id: string; role: Role }>('PATCH', `/tenants/${tenant}/members/${user}`, { role }),
	removeMember: (tenant: string, user: string) => request<void>('DELETE', `/tenants/${tenant}/members/${user}`),
	invite: (tenant: string, body: { role?: Role; expires_in_hours?: number }) =>
		request<InvitationCreated>('POST', `/tenants/${tenant}/invitations`, body)
};
