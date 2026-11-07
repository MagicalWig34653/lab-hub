import { ApiError, problemFromResponse } from './errors';
import type { components } from './types';

export { ApiError } from './errors';

type Schemas = components['schemas'];
export type SessionResponse = Schemas['SessionResponse'];
export type PasskeyInfo = Schemas['PasskeyInfo'];
export type PasskeyOptionsResponse = Schemas['PasskeyOptionsResponse'];
export type TenantMembership = Schemas['TenantMembership'];
export type Role = Schemas['Role'];
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
	addPasskeyOptions: () => request<PasskeyOptionsResponse>('POST', '/me/passkeys/options'),
	addPasskeyVerify: (body: VerifyBody) => request<PasskeyInfo>('POST', '/me/passkeys/verify', body)
};

export const tenantApi = {
	list: () => request<{ items: TenantMembership[] }>('GET', '/tenants')
};
