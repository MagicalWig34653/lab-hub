import type { components } from './types';

/** Error codes of the contract (Problem.code) plus codes the client raises itself. */
export type ProblemCode = components['schemas']['Problem']['code'];
export type ClientErrorCode = 'network_error' | 'session_ended' | 'unknown';

/** RFC 9457 problem+json from the backend, or a client-side failure (status 0). `code` drives the i18n text. */
export class ApiError extends Error {
	constructor(
		readonly status: number,
		readonly code: ProblemCode | ClientErrorCode | (string & {}),
		message: string = code,
		readonly requestId?: string,
		readonly fieldErrors: components['schemas']['FieldError'][] = [],
		readonly retryAfterSeconds?: number
	) {
		super(message);
		this.name = 'ApiError';
	}
}

/** Builds an ApiError from a fetch Response; non-problem bodies (proxy error pages) keep a generic status code. */
export async function problemFromResponse(response: Response): Promise<ApiError> {
	let code: string = `http_${response.status}`;
	let title = response.statusText;
	let requestId = response.headers.get('X-Request-Id') ?? undefined;
	let fieldErrors: components['schemas']['FieldError'][] = [];
	try {
		const body = (await response.json()) as Partial<components['schemas']['Problem']>;
		if (typeof body.code === 'string') code = body.code;
		if (typeof body.title === 'string') title = body.title;
		if (typeof body.request_id === 'string') requestId = body.request_id;
		if (Array.isArray(body.errors)) fieldErrors = body.errors;
	} catch {
		// not JSON
	}
	const retry = Number(response.headers.get('Retry-After'));
	return new ApiError(response.status, code, title, requestId, fieldErrors, Number.isFinite(retry) && retry > 0 ? retry : undefined);
}
