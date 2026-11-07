import { afterEach, describe, expect, it, vi } from 'vitest';
import { ApiError, authApi, setCsrfToken, setSessionEndedHandler, tenantApi } from './client';

function problem(status: number, code: string, extra: Record<string, unknown> = {}, headers: Record<string, string> = {}) {
	return new Response(JSON.stringify({ type: 'about:blank', title: 'Meldung', status, code, request_id: 'req-1', ...extra }), {
		status,
		headers: { 'content-type': 'application/problem+json', ...headers }
	});
}

afterEach(() => {
	vi.unstubAllGlobals();
	setCsrfToken(null);
	setSessionEndedHandler(null);
});

describe('api client', () => {
	it('turns problem+json into ApiError with code, request id and field errors', async () => {
		vi.stubGlobal(
			'fetch',
			vi.fn(async () => problem(422, 'validation_failed', { errors: [{ field: 'handle', code: 'invalid' }] }, { 'Retry-After': '7' }))
		);
		const error = await authApi.recoveryLogin({ handle: 'a', code: 'b' }).catch((e: unknown) => e);
		expect(error).toBeInstanceOf(ApiError);
		const api = error as ApiError;
		expect(api.status).toBe(422);
		expect(api.code).toBe('validation_failed');
		expect(api.requestId).toBe('req-1');
		expect(api.fieldErrors).toEqual([{ field: 'handle', code: 'invalid' }]);
		expect(api.retryAfterSeconds).toBe(7);
	});

	it('keeps a generic status code for non-JSON error bodies', async () => {
		vi.stubGlobal('fetch', vi.fn(async () => new Response('<html>bad gateway</html>', { status: 502 })));
		const error = (await tenantApi.list().catch((e: unknown) => e)) as ApiError;
		expect(error.code).toBe('http_502');
		expect(error.status).toBe(502);
	});

	it('reports a network failure as code network_error', async () => {
		vi.stubGlobal('fetch', vi.fn(async () => Promise.reject(new TypeError('offline'))));
		const error = (await authApi.session().catch((e: unknown) => e)) as ApiError;
		expect(error.code).toBe('network_error');
		expect(error.status).toBe(0);
	});

	it('sends the CSRF header on writes only, and JSON bodies with content type', async () => {
		const fetchMock = vi.fn(async () => new Response(null, { status: 204 }));
		vi.stubGlobal('fetch', fetchMock);
		setCsrfToken('csrf-1');
		await authApi.logout();
		await tenantApi.list().catch(() => undefined);
		const calls = fetchMock.mock.calls as unknown as [string, RequestInit][];
		expect((calls[0][1].headers as Record<string, string>)['X-CSRF-Token']).toBe('csrf-1');
		expect(calls[0][0]).toBe('/api/v1/auth/logout');
		expect((calls[1][1].headers as Record<string, string>)['X-CSRF-Token']).toBeUndefined();
	});

	it('maps 401 on a data call with a known session to session_ended and notifies', async () => {
		vi.stubGlobal('fetch', vi.fn(async () => problem(401, 'unauthorized')));
		const ended = vi.fn();
		setSessionEndedHandler(ended);
		setCsrfToken('csrf-1');
		const error = (await tenantApi.list().catch((e: unknown) => e)) as ApiError;
		expect(error.code).toBe('session_ended');
		expect(ended).toHaveBeenCalledOnce();
	});

	it('a 401 on an auth call is an ordinary failure, not a session end', async () => {
		vi.stubGlobal('fetch', vi.fn(async () => problem(401, 'login_failed')));
		const ended = vi.fn();
		setSessionEndedHandler(ended);
		setCsrfToken('csrf-1');
		const error = (await authApi.recoveryLogin({ handle: 'a', code: 'b' }).catch((e: unknown) => e)) as ApiError;
		expect(error.code).toBe('login_failed');
		expect(ended).not.toHaveBeenCalled();
	});
});
