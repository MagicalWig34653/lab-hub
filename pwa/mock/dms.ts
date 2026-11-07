import { createHash, randomUUID } from 'node:crypto';

/**
 * Mock of the DMS routes (contracts/openapi.yaml: dms/*, contacts list). Test double with synthetic data only.
 *
 * NOT in the contract (prepared for WP-O2/D3, flagged here on purpose, the UI treats them as optional):
 * - `ingest_state` / `ingest_error_code` on a document: processing state of the ingest item (`failed_permanent` = quarantine).
 *   The real upload response has no `ingest_item_id`, and there is no route that reports the ingest state yet.
 * Mock behaviour: an upload starts as status `processing` and becomes `needs_review` after `MOCK_PROCESSING_MS`
 * (the real backend leaves documents at `needs_review` until O2 exists). Text of a file is only searchable once
 * processing is done. A file containing the ASCII marker `MOCK-QUARANTINE` ends in quarantine.
 */

export const MOCK_MAX_UPLOAD_BYTES = 1024 * 1024;
export const MOCK_PROCESSING_MS = 700;
export const MOCK_QUARANTINE_MARKER = 'MOCK-QUARANTINE';
const START = '';
const END = '';

export interface DmsContext {
	method: string;
	parts: string[]; // path below /tenants/{t}/ e.g. ['dms','documents',id]
	query: URLSearchParams;
	headers: Record<string, string | string[] | undefined>;
	json: Record<string, unknown>;
	raw: Buffer;
	tenantId: string;
	permissions: string[];
	send: (status: number, body?: unknown, headers?: Record<string, string>) => void;
	sendRaw: (status: number, body: Buffer, headers: Record<string, string>) => void;
	fail: (status: number, code: string, title: string) => never;
}

interface MockDoc {
	id: string;
	title: string;
	doc_date: string | null;
	received_at: string;
	document_type_id: string | null;
	correspondent_id: string | null;
	asn: number | null;
	status: 'processing' | 'needs_review' | 'archived';
	trashed_at: string | null;
	trash_reason: string | null;
	created_at: string;
	updated_at: string;
	rev: number;
	tag_ids: string[];
	fields: Record<string, unknown>;
	file: { mime: string; bytes: Buffer; sha256: string; name: string };
	text: string;
	processingUntil: number;
	quarantined: boolean;
}

interface TenantData {
	docs: MockDoc[];
	types: { id: string; name: string }[];
	tags: { id: string; name: string }[];
	contacts: { id: string; name: string }[];
	fields: { id: string; name: string; code: string; data_type: string; options?: string[] }[];
	uploads: Map<string, { hash: string; body: unknown }>;
	nextAsn: number;
}

function detectMime(b: Buffer): string | null {
	if (b.subarray(0, 5).toString('latin1') === '%PDF-') return 'application/pdf';
	if (b.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return 'image/png';
	if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return 'image/jpeg';
	if (b.subarray(0, 4).toString('latin1') === 'RIFF' && b.subarray(8, 12).toString('latin1') === 'WEBP') return 'image/webp';
	return null;
}

function snippet(text: string, tokens: string[]): string | null {
	const lower = text.toLowerCase();
	const hit = tokens.map((t) => lower.indexOf(t)).filter((i) => i >= 0).sort((a, b) => a - b)[0];
	if (hit === undefined) return null;
	let out = text.slice(Math.max(0, hit - 30), hit + 80);
	for (const token of tokens) out = out.replace(new RegExp(token.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi'), (m) => START + m + END);
	return out;
}

export function createDmsMock() {
	let data = new Map<string, TenantData>();

	function reset() {
		data = new Map();
	}

	function tenantData(tenantId: string): TenantData {
		let d = data.get(tenantId);
		if (!d) {
			d = {
				docs: [],
				types: ['Rechnung', 'Vertrag', 'Brief'].map((name) => ({ id: randomUUID(), name })),
				tags: ['Steuer', 'Privat', 'Wichtig'].map((name) => ({ id: randomUUID(), name })),
				contacts: ['Muster GmbH', 'Beispiel AG'].map((name) => ({ id: randomUUID(), name })),
				fields: [
					{ id: randomUUID(), name: 'Rechnungsnummer', code: 'invoice_no', data_type: 'string' },
					{ id: randomUUID(), name: 'Priorität', code: 'priority', data_type: 'select', options: ['niedrig', 'hoch'] }
				],
				uploads: new Map(),
				nextAsn: 1
			};
			data.set(tenantId, d);
		}
		return d;
	}

	/** Processing completes by time; reading advances the state (the real backend does it with a worker). */
	function settle(doc: MockDoc) {
		if (doc.status === 'processing' && !doc.quarantined && Date.now() >= doc.processingUntil) doc.status = 'needs_review';
	}

	function publicDoc(d: TenantData, doc: MockDoc, detail: boolean) {
		settle(doc);
		const out: Record<string, unknown> = {
			id: doc.id,
			title: doc.title,
			doc_date: doc.doc_date,
			received_at: doc.received_at,
			document_type_id: doc.document_type_id,
			storage_path_id: null,
			correspondent_id: doc.correspondent_id,
			asn: doc.asn,
			status: doc.status,
			trashed_at: doc.trashed_at,
			trash_reason: doc.trash_reason,
			created_at: doc.created_at,
			updated_at: doc.updated_at,
			rev: doc.rev,
			// Mock-only, see file header.
			ingest_state: doc.quarantined ? 'failed_permanent' : doc.status === 'processing' ? 'ocr_queued' : 'done',
			...(doc.quarantined ? { ingest_error_code: 'ocr_failed' } : {})
		};
		if (detail) {
			out.tag_ids = doc.tag_ids;
			out.fields = doc.fields;
			out.files = [
				{ role: 'original', mime: doc.file.mime, size_bytes: doc.file.bytes.length, sha256: doc.file.sha256, page_count: 1, original_name: doc.file.name }
			];
		}
		void d;
		return out;
	}

	function page<T>(items: T[], query: URLSearchParams) {
		const limit = Math.min(200, Math.max(1, Number(query.get('limit') ?? 50)));
		const offset = query.get('cursor') ? Number(Buffer.from(query.get('cursor')!, 'base64url').toString()) : 0;
		const slice = items.slice(offset, offset + limit);
		const next = offset + limit < items.length ? Buffer.from(String(offset + limit)).toString('base64url') : null;
		return { items: slice, next_cursor: next, total: query.get('count') === 'true' ? items.length : null };
	}

	function find(d: TenantData, ctx: DmsContext, id: string): MockDoc {
		const doc = d.docs.find((x) => x.id === id);
		if (!doc) ctx.fail(404, 'not_found', 'Nicht gefunden');
		return doc;
	}

	function need(ctx: DmsContext, permission: string) {
		if (!ctx.permissions.includes(permission)) ctx.fail(403, 'forbidden', 'Keine Berechtigung');
	}

	function search(d: TenantData, ctx: DmsContext) {
		const q = (ctx.query.get('q') ?? '').trim();
		if (!q || q.length > 200) ctx.fail(422, 'validation_failed', 'Eingabe ungueltig');
		const tokens = q.toLowerCase().split(/\s+/).filter(Boolean);
		const tagIds = (ctx.query.get('tag_id') ?? '').split(',').filter(Boolean);
		const typeId = ctx.query.get('document_type_id');
		const corr = ctx.query.get('correspondent_id');
		const from = ctx.query.get('date_from');
		const to = ctx.query.get('date_to');
		const hits: { doc: MockDoc; snip: string | null }[] = [];
		for (const doc of d.docs) {
			settle(doc);
			if (doc.trashed_at) continue;
			// Text becomes searchable only after processing; title and metadata are searchable at once.
			const body = doc.status === 'processing' ? '' : doc.text;
			const haystack = `${doc.title} ${body}`.toLowerCase();
			if (!tokens.every((t) => haystack.includes(t))) continue;
			if (typeId && doc.document_type_id !== typeId) continue;
			if (corr && doc.correspondent_id !== corr) continue;
			if (!tagIds.every((t) => doc.tag_ids.includes(t))) continue;
			if (from && (!doc.doc_date || doc.doc_date < from)) continue;
			if (to && (!doc.doc_date || doc.doc_date > to)) continue;
			hits.push({ doc, snip: snippet(body || doc.title, tokens) });
		}
		hits.sort((a, b) => b.doc.created_at.localeCompare(a.doc.created_at));
		const result = page(
			hits.map(({ doc, snip }) => ({
				id: doc.id,
				title: doc.title,
				doc_date: doc.doc_date,
				document_type_id: doc.document_type_id,
				storage_path_id: null,
				correspondent_id: doc.correspondent_id,
				asn: doc.asn,
				status: doc.status,
				created_at: doc.created_at,
				score: 1.5,
				snippet: snip
			})),
			ctx.query
		);
		if (ctx.query.get('facets') !== 'true') return result;
		const count = (values: (string | null)[]) => {
			const m = new Map<string, number>();
			for (const v of values) if (v) m.set(v, (m.get(v) ?? 0) + 1);
			return [...m].map(([value, c]) => ({ value, count: c })).sort((a, b) => b.count - a.count);
		};
		return {
			...result,
			facets: {
				document_type: count(hits.map((h) => h.doc.document_type_id)),
				tag: count(hits.flatMap((h) => h.doc.tag_ids)),
				correspondent: count(hits.map((h) => h.doc.correspondent_id)),
				storage_path: [],
				year: count(hits.map((h) => h.doc.doc_date?.slice(0, 4) ?? null))
			}
		};
	}

	function upload(d: TenantData, ctx: DmsContext) {
		need(ctx, 'dms.document.create');
		const key = ctx.headers['idempotency-key'];
		if (typeof key !== 'string' || !key) ctx.fail(400, 'idempotency_key_required', 'Idempotency-Key fehlt');
		if (ctx.raw.length > MOCK_MAX_UPLOAD_BYTES) ctx.fail(413, 'payload_too_large', 'Zu gross');
		const mime = detectMime(ctx.raw);
		if (!mime) ctx.fail(415, 'unsupported_media_type', 'Dateityp nicht unterstuetzt');
		const sha256 = createHash('sha256').update(ctx.raw).digest('hex');
		const hash = `${sha256}:${ctx.query.get('filename') ?? ''}`;
		const stored = d.uploads.get(key);
		if (stored) {
			if (stored.hash !== hash) ctx.fail(422, 'idempotency_key_reused', 'Schluessel wiederverwendet');
			return ctx.send(201, stored.body);
		}
		const name = ctx.query.get('filename') ?? 'upload';
		const duplicates = d.docs.filter((x) => x.file.sha256 === sha256).map((x) => x.id);
		const text = ctx.raw.toString('latin1').replace(/[^\x20-\x7e\n]/g, ' ');
		const now = new Date().toISOString();
		const doc: MockDoc = {
			id: randomUUID(),
			title: ctx.query.get('title') ?? name.replace(/\.[^.]+$/, ''),
			doc_date: null,
			received_at: now,
			document_type_id: null,
			correspondent_id: null,
			asn: null,
			status: 'processing',
			trashed_at: null,
			trash_reason: null,
			created_at: now,
			updated_at: now,
			rev: 1,
			tag_ids: [],
			fields: {},
			file: { mime, bytes: ctx.raw, sha256, name },
			text,
			processingUntil: Date.now() + MOCK_PROCESSING_MS,
			quarantined: text.includes(MOCK_QUARANTINE_MARKER)
		};
		d.docs.push(doc);
		const body = { ...publicDoc(d, doc, true), duplicates };
		d.uploads.set(key, { hash, body });
		ctx.send(201, body);
	}

	function handle(ctx: DmsContext): boolean {
		const [dms, resource, id, action] = ctx.parts;
		if (dms !== 'dms') return false;
		const d = tenantData(ctx.tenantId);
		const m = ctx.method;

		if (m === 'POST' && resource === 'uploads') return upload(d, ctx), true;
		if (m === 'GET' && resource === 'search') return need(ctx, 'dms.document.read'), ctx.send(200, search(d, ctx)), true;
		if (m === 'GET' && resource === 'types') return need(ctx, 'dms.document.read'), ctx.send(200, { items: d.types.map((x) => ({ ...x, created_at: new Date().toISOString() })) }), true;
		if (m === 'GET' && resource === 'tags') return need(ctx, 'dms.document.read'), ctx.send(200, { items: d.tags.map((x) => ({ ...x, created_at: new Date().toISOString() })) }), true;
		if (m === 'GET' && resource === 'custom-fields') return need(ctx, 'dms.document.read'), ctx.send(200, { items: d.fields.map((x) => ({ ...x, created_at: new Date().toISOString() })) }), true;

		if (resource === 'documents' && !id && m === 'GET') {
			need(ctx, 'dms.document.read');
			const trashed = ctx.query.get('trashed') === 'true';
			const typeId = ctx.query.get('document_type_id');
			const corr = ctx.query.get('correspondent_id');
			const tag = ctx.query.get('tag_id');
			const status = ctx.query.get('status');
			const q = (ctx.query.get('q') ?? '').toLowerCase();
			const list = d.docs
				.filter((x) => (x.trashed_at !== null) === trashed)
				.filter((x) => !typeId || x.document_type_id === typeId)
				.filter((x) => !corr || x.correspondent_id === corr)
				.filter((x) => !tag || x.tag_ids.includes(tag))
				.filter((x) => !q || x.title.toLowerCase().includes(q))
				.filter((x) => !status || (settle(x), x.status === status))
				.sort((a, b) => b.created_at.localeCompare(a.created_at) || b.id.localeCompare(a.id));
			const result = page(list, ctx.query);
			return ctx.send(200, { ...result, items: result.items.map((x) => publicDoc(d, x, false)) }), true;
		}
		if (resource === 'documents' && id) {
			if (m === 'GET' && !action) return need(ctx, 'dms.document.read'), ctx.send(200, publicDoc(d, find(d, ctx, id), true)), true;
			if (m === 'GET' && action === 'file') {
				need(ctx, 'dms.document.read');
				const doc = find(d, ctx, id);
				const role = ctx.query.get('role') ?? 'original';
				if (role !== 'original') ctx.fail(404, 'not_found', 'Nicht gefunden');
				need(ctx, 'dms.document.download_original');
				return ctx.sendRaw(200, doc.file.bytes, {
					'content-type': doc.file.mime,
					'x-content-type-options': 'nosniff',
					'content-security-policy': "default-src 'none'; sandbox",
					'cache-control': 'private, no-store',
					'content-disposition': `${ctx.query.get('disposition') === 'inline' ? 'inline' : 'attachment'}; filename="${encodeURIComponent(doc.title)}"`
				}), true;
			}
			if (m === 'PATCH' && !action) {
				need(ctx, 'dms.document.update');
				const doc = find(d, ctx, id);
				if (doc.trashed_at) ctx.fail(409, 'document_trashed', 'Im Papierkorb');
				const ifMatch = ctx.headers['if-match'];
				if (typeof ifMatch === 'string' && Number(ifMatch) !== doc.rev) ctx.fail(412, 'precondition_failed', 'Geaendert');
				const b = ctx.json;
				if ('title' in b) {
					if (typeof b.title !== 'string' || !b.title.trim() || b.title.length > 300) ctx.fail(422, 'validation_failed', 'Eingabe ungueltig');
					doc.title = b.title;
				}
				if ('doc_date' in b) doc.doc_date = (b.doc_date as string | null) ?? null;
				if ('document_type_id' in b) doc.document_type_id = (b.document_type_id as string | null) ?? null;
				if ('correspondent_id' in b) doc.correspondent_id = (b.correspondent_id as string | null) ?? null;
				if (Array.isArray(b.tag_ids)) doc.tag_ids = b.tag_ids.map(String);
				if (b.fields && typeof b.fields === 'object') {
					for (const [code, value] of Object.entries(b.fields)) {
						if (value === null) delete doc.fields[code];
						else doc.fields[code] = value;
					}
				}
				doc.rev++;
				doc.updated_at = new Date().toISOString();
				return ctx.send(200, publicDoc(d, doc, true)), true;
			}
			if (m === 'POST' && action === 'archive') {
				need(ctx, 'dms.document.update');
				const doc = find(d, ctx, id);
				if (doc.trashed_at) ctx.fail(409, 'document_trashed', 'Im Papierkorb');
				doc.asn ??= d.nextAsn++;
				doc.status = 'archived';
				doc.rev++;
				return ctx.send(200, publicDoc(d, doc, true)), true;
			}
			if (m === 'POST' && action === 'trash') {
				need(ctx, 'dms.document.trash');
				const doc = find(d, ctx, id);
				const reason = ctx.json.reason;
				if (typeof reason !== 'string' || !reason.trim()) ctx.fail(422, 'validation_failed', 'Grund fehlt');
				if (doc.trashed_at) ctx.fail(409, 'document_trashed', 'Bereits im Papierkorb');
				doc.trashed_at = new Date().toISOString();
				doc.trash_reason = reason;
				doc.rev++;
				return ctx.send(200, publicDoc(d, doc, true)), true;
			}
			if (m === 'POST' && action === 'restore') {
				need(ctx, 'dms.document.trash');
				const doc = find(d, ctx, id);
				if (!doc.trashed_at) ctx.fail(409, 'conflict', 'Nicht im Papierkorb');
				doc.trashed_at = null;
				doc.trash_reason = null;
				doc.rev++;
				return ctx.send(200, publicDoc(d, doc, true)), true;
			}
		}
		return false;
	}

	/** Contacts (K5) as far as the DMS UI needs them. */
	function contacts(ctx: DmsContext) {
		const d = tenantData(ctx.tenantId);
		const q = (ctx.query.get('q') ?? '').toLowerCase();
		const items = d.contacts
			.filter((c) => !q || c.name.toLowerCase().includes(q))
			.map((c) => ({
				id: c.id,
				kind: 'organization',
				display_name: c.name,
				is_customer: false,
				is_supplier: true,
				is_correspondent: true,
				created_at: new Date().toISOString(),
				updated_at: new Date().toISOString()
			}));
		ctx.send(200, { items, next_cursor: null });
	}

	/** Test helper: `count` processed documents titled "Seed 001" … (newest first). */
	function seed(tenantId: string, count: number) {
		const d = tenantData(tenantId);
		for (let i = 0; i < count; i++) {
			const at = new Date(Date.now() - i * 1000).toISOString();
			d.docs.push({
				id: randomUUID(),
				title: `Seed ${String(i + 1).padStart(3, '0')}`,
				doc_date: null,
				received_at: at,
				document_type_id: null,
				correspondent_id: null,
				asn: null,
				status: 'needs_review',
				trashed_at: null,
				trash_reason: null,
				created_at: at,
				updated_at: at,
				rev: 1,
				tag_ids: [],
				fields: {},
				file: { mime: 'application/pdf', bytes: Buffer.from('%PDF-1.4 seed'), sha256: randomUUID(), name: 'seed.pdf' },
				text: 'seed',
				processingUntil: 0,
				quarantined: false
			});
		}
	}

	return { handle, contacts, reset, seed };
}
