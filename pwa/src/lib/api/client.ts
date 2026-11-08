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
export type DmsDocument = Schemas['DmsDocument'];
export type DmsFile = Schemas['DmsFile'];
export type DmsMaster = Schemas['DmsMaster'];
export type DmsSearchHit = Schemas['DmsSearchHit'];
export type DmsSearchPage = Schemas['DmsSearchPage'];
export type DmsFacets = Schemas['DmsFacets'];
export type DmsProcessing = Schemas['DmsProcessing'];
export type Contact = Schemas['Contact'];
export type DmsRule = Schemas['DmsRule'];
export type DmsRuleInput = Schemas['DmsRuleInput'];
export type DmsRulePreview = Schemas['DmsRulePreview'];
export type DmsSuggestion = Schemas['DmsSuggestion'];
export type DmsDuplicate = Schemas['DmsDuplicate'];
export type DmsRetention = Schemas['DmsRetention'];
export type DmsPurge = Schemas['DmsPurge'];
export type DmsDeletionLogEntry = Schemas['DmsDeletionLogEntry'];
export type DmsIntegrityRun = Schemas['DmsIntegrityRun'];
export type DmsExport = Schemas['DmsExport'];
export type DmsExportParams = Schemas['DmsExportParams'];
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

async function request<T>(method: Method, path: string, body?: unknown, extraHeaders: Record<string, string> = {}): Promise<T> {
	const headers: Record<string, string> = { Accept: 'application/json, application/problem+json', ...extraHeaders };
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

type Query = Record<string, string | number | boolean | undefined | null>;

function withQuery(path: string, query: Query): string {
	const params = new URLSearchParams();
	for (const [key, value] of Object.entries(query)) {
		if (value !== undefined && value !== null && value !== '') params.set(key, String(value));
	}
	const text = params.toString();
	return text ? `${path}?${text}` : path;
}

export interface DocumentPage {
	items: DmsDocument[];
	next_cursor?: string | null;
	total?: number | null;
}

export interface DocumentListQuery {
	trashed?: boolean;
	status?: DmsDocument['status'];
	document_type_id?: string;
	tag_id?: string;
	correspondent_id?: string;
	q?: string;
	cursor?: string | null;
	limit?: number;
}

export interface SearchQuery {
	/** Empty or omitted: browse without a search term (snippet is null). */
	q?: string;
	cursor?: string | null;
	limit?: number;
	facets?: boolean;
	document_type_id?: string;
	correspondent_id?: string;
	/** Comma separated tag ids; every tag must match. */
	tag_id?: string;
	date_from?: string;
	date_to?: string;
}

export interface UploadOptions {
	filename: string;
	idempotencyKey: string;
	onProgress?: (fraction: number) => void;
	signal?: AbortSignal;
}

/**
 * Upload of one file: raw body, no multipart (contract `dmsUpload`). XMLHttpRequest instead of fetch because only XHR
 * reports upload progress. Same cookie + CSRF rules as `request`.
 */
function uploadFile(tenant: string, file: Blob, options: UploadOptions): Promise<DmsDocument> {
	return new Promise((resolve, reject) => {
		const xhr = new XMLHttpRequest();
		xhr.open('POST', withQuery(`${BASE}/tenants/${tenant}/dms/uploads`, { filename: options.filename }));
		xhr.withCredentials = true;
		xhr.setRequestHeader('Accept', 'application/json, application/problem+json');
		xhr.setRequestHeader('Content-Type', 'application/octet-stream');
		xhr.setRequestHeader('Idempotency-Key', options.idempotencyKey);
		if (csrfToken) xhr.setRequestHeader('X-CSRF-Token', csrfToken);
		xhr.upload.onprogress = (event) => {
			if (event.lengthComputable) options.onProgress?.(event.loaded / event.total);
		};
		xhr.onerror = () => reject(new ApiError(0, 'network_error'));
		xhr.onabort = () => reject(new ApiError(0, 'aborted'));
		xhr.onload = () => {
			let parsed: unknown;
			try {
				parsed = xhr.responseText ? JSON.parse(xhr.responseText) : undefined;
			} catch {
				parsed = undefined;
			}
			if (xhr.status >= 200 && xhr.status < 300) return resolve(parsed as DmsDocument);
			const problem = (parsed ?? {}) as Partial<Schemas['Problem']>;
			if (xhr.status === 401 && csrfToken !== null) sessionEndedHandler?.();
			reject(
				new ApiError(
					xhr.status,
					typeof problem.code === 'string' ? problem.code : `http_${xhr.status}`,
					typeof problem.title === 'string' ? problem.title : xhr.statusText,
					typeof problem.request_id === 'string' ? problem.request_id : undefined
				)
			);
		};
		options.signal?.addEventListener('abort', () => xhr.abort(), { once: true });
		xhr.send(file);
	});
}

/** DMS routes (WP-D2/S1). Master data lists are small (no paging in the contract). */
export const dmsApi = {
	documents: (tenant: string, query: DocumentListQuery = {}) =>
		request<DocumentPage>('GET', withQuery(`/tenants/${tenant}/dms/documents`, { ...query })),
	search: (tenant: string, query: SearchQuery) =>
		request<DmsSearchPage>('GET', withQuery(`/tenants/${tenant}/dms/search`, { ...query })),
	document: (tenant: string, id: string) => request<DmsDocument>('GET', `/tenants/${tenant}/dms/documents/${id}`),
	processing: (tenant: string, id: string) => request<DmsProcessing>('GET', `/tenants/${tenant}/dms/documents/${id}/processing`),
	retryProcessing: (tenant: string, id: string) => request<DmsProcessing>('POST', `/tenants/${tenant}/dms/documents/${id}/processing/retry`),
	update: (tenant: string, id: string, patch: Record<string, unknown>, rev?: number) =>
		request<DmsDocument>('PATCH', `/tenants/${tenant}/dms/documents/${id}`, patch, rev === undefined ? undefined : { 'If-Match': String(rev) }),
	archive: (tenant: string, id: string) => request<DmsDocument>('POST', `/tenants/${tenant}/dms/documents/${id}/archive`),
	trash: (tenant: string, id: string, reason: string) =>
		request<DmsDocument>('POST', `/tenants/${tenant}/dms/documents/${id}/trash`, { reason }),
	restore: (tenant: string, id: string) => request<DmsDocument>('POST', `/tenants/${tenant}/dms/documents/${id}/restore`),
	/** URL of the file route (same origin, cookie auth); `inline` for preview, `attachment` for download. */
	fileUrl: (tenant: string, id: string, role: DmsFile['role'], disposition: 'inline' | 'attachment') =>
		withQuery(`${BASE}/tenants/${tenant}/dms/documents/${id}/file`, { role, disposition }),
	/** Fetches a file for inline preview (blob URL in the page; the response carries nosniff + CSP sandbox, so it is never navigated to). */
	fileBlob: async (tenant: string, id: string, role: DmsFile['role']): Promise<Blob> => {
		let response: Response;
		try {
			response = await fetch(withQuery(`${BASE}/tenants/${tenant}/dms/documents/${id}/file`, { role, disposition: 'inline' }), {
				credentials: 'same-origin'
			});
		} catch {
			throw new ApiError(0, 'network_error');
		}
		if (!response.ok) throw await problemFromResponse(response);
		return response.blob();
	},
	types: (tenant: string) => request<{ items: DmsMaster[] }>('GET', `/tenants/${tenant}/dms/types`),
	tags: (tenant: string) => request<{ items: DmsMaster[] }>('GET', `/tenants/${tenant}/dms/tags`),
	customFields: (tenant: string) => request<{ items: DmsMaster[] }>('GET', `/tenants/${tenant}/dms/custom-fields`),
	upload: uploadFile
};

export interface Page<T> {
	items: T[];
	next_cursor: string | null;
	total?: number | null;
}

/** Master data resources with their path segment (contract: dms/types, tags, tag-groups, storage-paths, custom-fields). */
export type MasterResource = 'types' | 'tag-groups' | 'tags' | 'storage-paths' | 'custom-fields';

/** WP-D3/D5 routes: rules, suggestions, duplicates, retention and purge, integrity runs, exports, master data maintenance. */
export const dmsAdminApi = {
	suggestions: (tenant: string, query: { state?: 'open' | 'accepted' | 'rejected' | 'all'; kind?: string; document_id?: string; rule_id?: string; cursor?: string | null; limit?: number; count?: boolean } = {}) =>
		request<Page<DmsSuggestion>>('GET', withQuery(`/tenants/${tenant}/dms/suggestions`, { ...query })),
	documentSuggestions: (tenant: string, document: string, state: 'open' | 'accepted' | 'rejected' | 'all' = 'open') =>
		request<Page<DmsSuggestion>>('GET', withQuery(`/tenants/${tenant}/dms/documents/${document}/suggestions`, { state })),
	acceptSuggestion: (tenant: string, id: string) => request<DmsSuggestion>('POST', `/tenants/${tenant}/dms/suggestions/${id}/accept`),
	rejectSuggestion: (tenant: string, id: string) => request<DmsSuggestion>('POST', `/tenants/${tenant}/dms/suggestions/${id}/reject`),

	rules: (tenant: string) => request<Page<DmsRule>>('GET', withQuery(`/tenants/${tenant}/dms/rules`, { limit: 200 })),
	createRule: (tenant: string, body: DmsRuleInput) => request<DmsRule>('POST', `/tenants/${tenant}/dms/rules`, body),
	updateRule: (tenant: string, id: string, body: DmsRuleInput) => request<DmsRule>('PATCH', `/tenants/${tenant}/dms/rules/${id}`, body),
	deleteRule: (tenant: string, id: string) => request<void>('DELETE', `/tenants/${tenant}/dms/rules/${id}`),
	previewDraft: (tenant: string, body: DmsRuleInput) => request<DmsRulePreview>('POST', `/tenants/${tenant}/dms/rules/preview`, body),
	previewRule: (tenant: string, id: string, limit?: number) =>
		request<DmsRulePreview>('POST', `/tenants/${tenant}/dms/rules/${id}/preview`, limit === undefined ? undefined : { limit }),

	duplicates: (tenant: string, query: { state?: 'open' | 'confirmed' | 'dismissed' | 'all'; method?: string; document_id?: string; cursor?: string | null; limit?: number } = {}) =>
		request<Page<DmsDuplicate>>('GET', withQuery(`/tenants/${tenant}/dms/duplicates`, { ...query })),
	resolveDuplicate: (tenant: string, id: string, state: 'confirmed' | 'dismissed') =>
		request<DmsDuplicate>('POST', `/tenants/${tenant}/dms/duplicates/${id}/resolve`, { state }),

	retention: (tenant: string, document: string) => request<DmsRetention>('GET', `/tenants/${tenant}/dms/documents/${document}/retention`),
	setRetention: (tenant: string, document: string, body: { legal_hold?: boolean; retention_until?: string }) =>
		request<DmsRetention>('PATCH', `/tenants/${tenant}/dms/documents/${document}/retention`, body),
	purge: (tenant: string, document: string) => request<DmsPurge>('POST', `/tenants/${tenant}/dms/documents/${document}/purge`),
	deletionLog: (tenant: string) => request<{ items: DmsDeletionLogEntry[] }>('GET', `/tenants/${tenant}/dms/deletion-log`),

	integrityRuns: (tenant: string) => request<{ items: DmsIntegrityRun[] }>('GET', `/tenants/${tenant}/dms/integrity-runs`),
	integrityRun: (tenant: string, id: string) => request<DmsIntegrityRun>('GET', `/tenants/${tenant}/dms/integrity-runs/${id}`),
	startIntegrityRun: (tenant: string) => request<DmsIntegrityRun>('POST', `/tenants/${tenant}/dms/integrity-runs`),

	exports: (tenant: string) => request<{ items: DmsExport[] }>('GET', `/tenants/${tenant}/dms/exports`),
	exportJob: (tenant: string, id: string) => request<DmsExport>('GET', `/tenants/${tenant}/dms/exports/${id}`),
	startExport: (tenant: string, params: DmsExportParams) => request<DmsExport>('POST', `/tenants/${tenant}/dms/exports`, params),
	exportFileUrl: (tenant: string, id: string) => `${BASE}/tenants/${tenant}/dms/exports/${id}/file`,

	masters: (tenant: string, resource: MasterResource) => request<{ items: DmsMaster[] }>('GET', `/tenants/${tenant}/dms/${resource}`),
	createMaster: (tenant: string, resource: MasterResource, body: Record<string, unknown>) =>
		request<DmsMaster>('POST', `/tenants/${tenant}/dms/${resource}`, body),
	updateMaster: (tenant: string, resource: MasterResource, id: string, body: Record<string, unknown>) =>
		request<DmsMaster>('PATCH', `/tenants/${tenant}/dms/${resource}/${id}`, body),
	deleteMaster: (tenant: string, resource: MasterResource, id: string) => request<void>('DELETE', `/tenants/${tenant}/dms/${resource}/${id}`)
};

/** Contacts are the correspondents of documents (K5); only listing is needed here. */
export const contactApi = {
	list: (tenant: string, query: { q?: string; limit?: number; cursor?: string | null } = {}) =>
		request<{ items: Contact[]; next_cursor: string | null }>('GET', withQuery(`/tenants/${tenant}/contacts`, { ...query }))
};
