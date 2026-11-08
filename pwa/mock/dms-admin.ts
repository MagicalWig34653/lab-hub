import { createHash, randomUUID } from 'node:crypto';
import type { DmsContext, MockDoc, TenantData } from './dms.ts';

/**
 * Mock of the WP-D3/D5 DMS routes (contracts/openapi.yaml): suggestions, rules with dry run, duplicates, retention and
 * purge, deletion log, integrity runs, exports and master data maintenance. Test double with synthetic data only.
 *
 * Behaviour that tests rely on:
 * - Rules are evaluated on upload (text = printable bytes of the file, file name) and create suggestions (mode suggest)
 *   or apply empty values at once (mode auto). The dry run evaluates existing, non-trashed documents.
 * - The pattern `(a+)+$` counts as catastrophic: the dry run reports `timed_out` for documents whose text contains "aaaa".
 *   An invalid regular expression answers 422 `validation_failed` with a field error `invalid_regex`.
 * - `MOCK-TAMPER` in a file makes the integrity run `failed` (hash_mismatch finding) and exports `failed` (integrity_failed).
 * - Integrity runs and exports finish after `ADMIN_JOB_MS`.
 * - Retention: end of the calendar year of the document date (else the received date) plus 10 years; a legal hold or a
 *   manual extension counts like in the backend. Purge needs `dms.document.purge` (owner in the mock).
 */

export const ADMIN_JOB_MS = 600;
export const MOCK_TAMPER_MARKER = 'MOCK-TAMPER';
const DEFAULT_RETENTION_YEARS = 10;

interface Condition {
	type: string;
	value?: string;
	pattern?: string;
	case_sensitive?: boolean;
}
interface Rule {
	id: string;
	name: string;
	priority: number;
	enabled: boolean;
	mode: 'suggest' | 'auto';
	confidence: number;
	conditions: { version?: number; match?: 'all' | 'any'; conditions: Condition[] };
	actions: Record<string, unknown>;
	version: number;
	created_at: string;
	updated_at: string;
	deleted: boolean;
}
interface Suggestion {
	id: string;
	document_id: string;
	kind: 'correspondent' | 'type' | 'tag' | 'date' | 'title' | 'path';
	value: Record<string, string>;
	source: 'rule' | 'contact_match';
	rule_id: string | null;
	rule_version: number | null;
	confidence: number;
	reason: string;
	evidence: Record<string, string>;
	state: 'open' | 'accepted' | 'rejected';
	applied_automatically: boolean;
	decided_at: string | null;
	created_at: string;
}
interface Duplicate {
	id: string;
	document_id: string;
	duplicate_of: string;
	method: 'sha256' | 'text_hash' | 'similarity';
	score: number;
	state: 'open' | 'confirmed' | 'dismissed';
	decided_at: string | null;
	created_at: string;
}
interface IntegrityRun {
	id: string;
	created_at: string;
	readyAt: number;
	findings: { document_id: string; role: string; problem: string }[];
	checked: number;
}
interface ExportJob {
	id: string;
	params: Record<string, unknown>;
	created_at: string;
	readyAt: number;
	failedCode: string | null;
	docs: MockDoc[];
	zip: Buffer;
}
interface LogEntry {
	id: string;
	document_id: string;
	asn: number | null;
	document_type_id: string | null;
	doc_date: string | null;
	retention_until: string | null;
	original_sha256: string;
	original_size: number;
	file_count: number;
	purged_at: string;
}

export interface AdminState {
	rules: Rule[];
	suggestions: Suggestion[];
	duplicates: Duplicate[];
	runs: IntegrityRun[];
	exports: ExportJob[];
	log: LogEntry[];
}

export function newAdminState(): AdminState {
	return { rules: [], suggestions: [], duplicates: [], runs: [], exports: [], log: [] };
}

interface Host {
	publicDoc: (doc: MockDoc) => Record<string, unknown>;
	page: <T>(items: T[], query: URLSearchParams) => { items: T[]; next_cursor: string | null; total: number | null };
}

// ---------------------------------------------------------------- rule evaluation

function escapeRe(text: string): string {
	return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

const CATASTROPHIC = '(a+)+$';

type Outcome = { met: boolean; timedOut: boolean; match: { type: string; matched: string; offset: number | null; length: number | null } | null };

function evalCondition(c: Condition, doc: MockDoc): Outcome {
	const flags = c.case_sensitive ? '' : 'i';
	const none: Outcome = { met: false, timedOut: false, match: null };
	if (c.type === 'source_is') return c.value === 'upload' ? { met: true, timedOut: false, match: { type: c.type, matched: 'upload', offset: null, length: null } } : none;
	if (c.type === 'sender_contains') return none;
	const haystack = c.type.startsWith('filename') ? doc.file.name : doc.text;
	let re: RegExp;
	if (c.type.endsWith('_regex')) {
		if (c.pattern === CATASTROPHIC) return /aaaa/.test(haystack) ? { met: false, timedOut: true, match: null } : none;
		re = new RegExp(c.pattern ?? '', flags);
	} else re = new RegExp(escapeRe(c.value ?? ''), flags);
	const m = re.exec(haystack);
	if (!m) return none;
	return { met: true, timedOut: false, match: { type: c.type, matched: m[0].slice(0, 80), offset: m.index, length: m[0].length } };
}

function evalRule(rule: Pick<Rule, 'conditions'>, doc: MockDoc) {
	const outcomes = rule.conditions.conditions.map((c) => evalCondition(c, doc));
	const timedOut = outcomes.some((o) => o.timedOut);
	const any = rule.conditions.match === 'any';
	const met = any ? outcomes.some((o) => o.met) : outcomes.every((o) => o.met);
	return { met, timedOut, matches: outcomes.flatMap((o) => (o.match ? [o.match] : [])) };
}

function extractedDate(text: string): string | null {
	const iso = /\b(\d{4})-(\d{2})-(\d{2})\b/.exec(text);
	if (iso) return iso[0];
	const de = /\b(\d{1,2})\.(\d{1,2})\.(\d{4})\b/.exec(text);
	return de ? `${de[3]}-${de[2].padStart(2, '0')}-${de[1].padStart(2, '0')}` : null;
}

interface Candidate {
	kind: Suggestion['kind'];
	value: Record<string, string>;
	reason: string;
}

/** Candidates of a rule for a document: what the document does not have yet (like DMSRuleEngine). */
function candidates(rule: Pick<Rule, 'name' | 'actions'>, doc: MockDoc, matched: string): Candidate[] {
	const a = rule.actions;
	const reason = `Regel "${rule.name}", Treffer "${matched}"`;
	const out: Candidate[] = [];
	if (typeof a.correspondent_id === 'string' && !doc.correspondent_id) out.push({ kind: 'correspondent', value: { contact_id: a.correspondent_id }, reason });
	if (typeof a.document_type_id === 'string' && !doc.document_type_id) out.push({ kind: 'type', value: { document_type_id: a.document_type_id }, reason });
	for (const tag of Array.isArray(a.tag_ids) ? (a.tag_ids as string[]) : []) if (!doc.tag_ids.includes(tag)) out.push({ kind: 'tag', value: { tag_id: tag }, reason });
	if (typeof a.storage_path_id === 'string' && !doc.storage_path_id) out.push({ kind: 'path', value: { storage_path_id: a.storage_path_id }, reason });
	if (typeof a.doc_date === 'string' && !doc.doc_date) {
		const date = a.doc_date === 'extracted' ? extractedDate(doc.text) : a.doc_date;
		if (date) out.push({ kind: 'date', value: { doc_date: date }, reason });
	}
	if (typeof a.title_template === 'string' && a.title_template.trim()) {
		const title = a.title_template
			.replaceAll('{filename}', doc.file.name.replace(/\.[^.]+$/, ''))
			.replaceAll('{match}', matched)
			.replaceAll('{date}', doc.doc_date ?? extractedDate(doc.text) ?? '');
		if (title.trim() && title !== doc.title) out.push({ kind: 'title', value: { title }, reason });
	}
	return out;
}

function apply(d: TenantData, doc: MockDoc, kind: Suggestion['kind'], value: Record<string, string>) {
	if (kind === 'correspondent') doc.correspondent_id = value.contact_id;
	else if (kind === 'type') doc.document_type_id = value.document_type_id;
	else if (kind === 'tag') doc.tag_ids = [...new Set([...doc.tag_ids, value.tag_id])];
	else if (kind === 'path') doc.storage_path_id = value.storage_path_id;
	else if (kind === 'date') doc.doc_date = value.doc_date;
	else doc.title = value.title;
	doc.rev++;
	doc.updated_at = new Date().toISOString();
	void d;
}

function targetExists(d: TenantData, s: Suggestion): boolean {
	if (s.kind === 'type') return d.types.some((x) => x.id === s.value.document_type_id);
	if (s.kind === 'tag') return d.tags.some((x) => x.id === s.value.tag_id);
	if (s.kind === 'path') return d.paths.some((x) => x.id === s.value.storage_path_id);
	if (s.kind === 'correspondent') return d.contacts.some((x) => x.id === s.value.contact_id);
	return true;
}

let stampCounter = 0;
/** Strictly increasing timestamps, so suggestions keep their creation order in lists. */
const stamp = () => new Date(Date.now() + (stampCounter++ % 100000)).toISOString();

/** Called for every new document: duplicate hints and rule suggestions (Auto rules apply empty values). */
export function onUploaded(d: TenantData, doc: MockDoc, duplicateOf: string[]) {
	for (const other of duplicateOf) {
		const now = stamp();
		d.admin.duplicates.push({ id: randomUUID(), document_id: doc.id, duplicate_of: other, method: 'sha256', score: 1, state: 'open', decided_at: null, created_at: now });
	}
	const rules = d.admin.rules.filter((r) => r.enabled && !r.deleted).sort((a, b) => b.priority - a.priority);
	for (const rule of rules) {
		const result = evalRule(rule, doc);
		if (!result.met) continue;
		const matched = result.matches[0]?.matched ?? '';
		for (const c of candidates(rule, doc, matched)) {
			const now = stamp();
			const auto = rule.mode === 'auto';
			if (auto) apply(d, doc, c.kind, c.value);
			d.admin.suggestions.push({
				id: randomUUID(),
				document_id: doc.id,
				kind: c.kind,
				value: c.value,
				source: 'rule',
				rule_id: rule.id,
				rule_version: rule.version,
				confidence: rule.confidence,
				reason: c.reason,
				evidence: { matched },
				state: auto ? 'accepted' : 'open',
				applied_automatically: auto,
				decided_at: auto ? now : null,
				created_at: now
			});
		}
	}
}

// ---------------------------------------------------------------- retention

function retentionOf(d: TenantData, doc: MockDoc) {
	const type = d.types.find((t) => t.id === doc.document_type_id) as { default_retention_years?: number } | undefined;
	const years = type?.default_retention_years ?? DEFAULT_RETENTION_YEARS;
	const source = type?.default_retention_years !== undefined ? 'document_type' : 'default';
	const base = doc.doc_date ?? doc.received_at.slice(0, 10);
	const computed = years === 0 ? null : `${Number(base.slice(0, 4)) + years}-12-31`;
	let until = computed;
	let effective = computed ? source : 'none';
	if (doc.retention_override && (!until || doc.retention_override > until)) {
		until = doc.retention_override;
		effective = 'manual';
	}
	const trashed = doc.trashed_at !== null;
	const blockers: string[] = [];
	if (!trashed) blockers.push('document_not_trashed');
	if (doc.legal_hold) blockers.push('legal_hold');
	if (until && until >= new Date().toISOString().slice(0, 10)) blockers.push('retention_not_expired');
	return {
		document_id: doc.id,
		legal_hold: doc.legal_hold,
		retention_until: until,
		retention_source: effective,
		retention_override: doc.retention_override,
		trashed,
		blockers,
		can_purge: blockers.length === 0,
		note: 'GoBD-orientiert, keine Rechtsberatung'
	};
}

// ---------------------------------------------------------------- handler

const MASTER_PERMISSION: Record<string, string> = {
	types: 'dms.master.manage',
	'tag-groups': 'dms.tag.manage',
	tags: 'dms.tag.manage',
	'storage-paths': 'dms.master.manage',
	'custom-fields': 'dms.master.manage'
};

function masterList(d: TenantData, resource: string): Record<string, unknown>[] | null {
	switch (resource) {
		case 'types':
			return d.types as unknown as Record<string, unknown>[];
		case 'tags':
			return d.tags as unknown as Record<string, unknown>[];
		case 'tag-groups':
			return d.groups as unknown as Record<string, unknown>[];
		case 'storage-paths':
			return d.paths as unknown as Record<string, unknown>[];
		case 'custom-fields':
			return d.fields as unknown as Record<string, unknown>[];
		default:
			return null;
	}
}

const MASTER_KEYS: Record<string, string[]> = {
	types: ['name', 'code', 'description', 'default_retention_years'],
	'tag-groups': ['name', 'exclusive'],
	tags: ['name', 'group_id', 'color'],
	'storage-paths': ['name', 'template'],
	'custom-fields': ['name', 'code', 'data_type', 'options']
};

function usedBy(d: TenantData, resource: string, id: string): boolean {
	if (resource === 'types') return d.docs.some((x) => x.document_type_id === id);
	if (resource === 'tags') return d.docs.some((x) => x.tag_ids.includes(id));
	if (resource === 'storage-paths') return d.docs.some((x) => x.storage_path_id === id);
	if (resource === 'tag-groups') return d.tags.some((x) => (x as { group_id?: string }).group_id === id);
	return d.docs.some((x) => id in x.fields);
}

export function handleAdmin(d: TenantData, ctx: DmsContext, host: Host): boolean {
	const [, resource, id, action] = ctx.parts;
	const m = ctx.method;
	const now = () => new Date().toISOString();
	const need = (permission: string) => {
		if (!ctx.permissions.includes(permission)) ctx.fail(403, 'forbidden', 'Keine Berechtigung');
	};
	const send = ctx.send;
	const admin = d.admin;
	const validation = (field: string, code: string) => {
		send(422, { type: 'about:blank', title: 'Eingabe ungueltig', status: 422, code: 'validation_failed', request_id: randomUUID(), errors: [{ field, code }] });
		return true;
	};

	// ----- master data (list, create, rename, delete)
	const list = resource ? masterList(d, resource) : null;
	if (list) {
		const keys = MASTER_KEYS[resource];
		if (m === 'GET' && !id) {
			need('dms.document.read');
			return send(200, { items: list.map((x) => ({ created_at: now(), ...x })) }), true;
		}
		if (m === 'POST' && !id) {
			need(MASTER_PERMISSION[resource]);
			const body = ctx.json;
			if (typeof body.name !== 'string' || !body.name.trim()) return validation('name', 'required');
			if (resource === 'custom-fields' && (typeof body.code !== 'string' || typeof body.data_type !== 'string')) return validation('code', 'required');
			if (resource === 'storage-paths' && typeof body.template !== 'string') return validation('template', 'required');
			if (list.some((x) => String(x.name).toLowerCase() === String(body.name).trim().toLowerCase())) ctx.fail(409, 'conflict', 'Name bereits vergeben');
			const row: Record<string, unknown> = { id: randomUUID() };
			for (const key of keys) if (key in body) row[key] = key === 'name' ? String(body.name).trim() : body[key];
			list.push(row);
			return send(201, { created_at: now(), ...row }), true;
		}
		if (id && m === 'PATCH') {
			need(MASTER_PERMISSION[resource]);
			const row = list.find((x) => x.id === id);
			if (!row) ctx.fail(404, 'not_found', 'Nicht gefunden');
			for (const locked of ['code', 'data_type']) if (resource === 'custom-fields' && locked in ctx.json) return validation(locked, 'immutable');
			for (const key of keys) if (key in ctx.json) row![key] = ctx.json[key];
			return send(200, { created_at: now(), ...row }), true;
		}
		if (id && m === 'DELETE') {
			need(MASTER_PERMISSION[resource]);
			const index = list.findIndex((x) => x.id === id);
			if (index < 0) ctx.fail(404, 'not_found', 'Nicht gefunden');
			if (usedBy(d, resource, id)) ctx.fail(409, 'conflict', 'Wird verwendet');
			list.splice(index, 1);
			return send(204), true;
		}
		return false;
	}

	// ----- suggestions
	const suggestionOut = (s: Suggestion) => ({
		...s,
		document_title: d.docs.find((x) => x.id === s.document_id)?.title ?? '',
		decided_by: s.decided_at ? '00000000-0000-4000-8000-000000000001' : null
	});
	const suggestionPage = (filter: (s: Suggestion) => boolean) => {
		const state = ctx.query.get('state') ?? 'open';
		const kind = ctx.query.get('kind');
		const items = admin.suggestions
			.filter((s) => (state === 'all' || s.state === state) && (!kind || s.kind === kind))
			.filter((s) => d.docs.find((x) => x.id === s.document_id)?.trashed_at === null)
			.filter(filter)
			.sort((a, b) => a.created_at.localeCompare(b.created_at) || a.id.localeCompare(b.id));
		const page = host.page(items, ctx.query);
		return { ...page, items: page.items.map(suggestionOut) };
	};
	if (resource === 'suggestions' && !id && m === 'GET') {
		need('dms.suggestion.read');
		const docId = ctx.query.get('document_id');
		const ruleId = ctx.query.get('rule_id');
		return send(200, suggestionPage((s) => (!docId || s.document_id === docId) && (!ruleId || s.rule_id === ruleId))), true;
	}
	if (resource === 'documents' && id && action === 'suggestions' && m === 'GET') {
		need('dms.suggestion.read');
		return send(200, suggestionPage((s) => s.document_id === id)), true;
	}
	if (resource === 'suggestions' && id && m === 'POST' && (action === 'accept' || action === 'reject')) {
		need('dms.suggestion.decide');
		const s = admin.suggestions.find((x) => x.id === id);
		if (!s) ctx.fail(404, 'not_found', 'Nicht gefunden');
		const doc = d.docs.find((x) => x.id === s!.document_id)!;
		if (s!.state !== 'open') ctx.fail(409, 'suggestion_decided', 'Schon entschieden');
		if (action === 'accept') {
			if (doc.trashed_at) ctx.fail(409, 'document_trashed', 'Im Papierkorb');
			if (!targetExists(d, s!)) ctx.fail(409, 'suggestion_stale', 'Veraltet');
			apply(d, doc, s!.kind, s!.value);
			s!.state = 'accepted';
		} else s!.state = 'rejected';
		s!.decided_at = now();
		return send(200, suggestionOut(s!)), true;
	}

	// ----- rules
	const ruleOut = (r: Rule) => {
		const mine = admin.suggestions.filter((s) => s.rule_id === r.id);
		return {
			id: r.id,
			name: r.name,
			priority: r.priority,
			enabled: r.enabled,
			mode: r.mode,
			confidence: r.confidence,
			conditions: r.conditions,
			actions: r.actions,
			version: r.version,
			created_by: null,
			created_at: r.created_at,
			updated_at: r.updated_at,
			stats: {
				suggested: mine.length,
				open: mine.filter((s) => s.state === 'open').length,
				accepted: mine.filter((s) => s.state === 'accepted' && !s.applied_automatically).length,
				rejected: mine.filter((s) => s.state === 'rejected').length,
				automatic: mine.filter((s) => s.applied_automatically).length
			}
		};
	};
	/** Validates a rule body (create: full; patch: merged over the existing rule). Answers 422 itself and returns null. */
	const checkRule = (body: Record<string, unknown>): Pick<Rule, 'name' | 'priority' | 'enabled' | 'mode' | 'confidence' | 'conditions' | 'actions'> | null => {
		const name = typeof body.name === 'string' ? body.name.trim() : '';
		if (!name || name.length > 100) return validation('name', 'invalid'), null;
		const conditions = body.conditions as Rule['conditions'] | undefined;
		if (!conditions || !Array.isArray(conditions.conditions) || conditions.conditions.length < 1 || conditions.conditions.length > 20) return validation('conditions', 'invalid'), null;
		for (const c of conditions.conditions) {
			if (c.type.endsWith('_regex')) {
				if (!c.pattern || c.pattern.length > 200) return validation('conditions', 'invalid_regex'), null;
				try {
					new RegExp(c.pattern);
				} catch {
					return validation('conditions', 'invalid_regex'), null;
				}
			} else if (!c.value) return validation('conditions', 'invalid'), null;
		}
		const actions = (body.actions ?? {}) as Record<string, unknown>;
		if (Object.keys(actions).length === 0) return validation('actions', 'required'), null;
		const refs: [string, string, string | undefined][] = [
			['document_type_id', 'type', typeof actions.document_type_id === 'string' ? actions.document_type_id : undefined],
			['storage_path_id', 'path', typeof actions.storage_path_id === 'string' ? actions.storage_path_id : undefined]
		];
		for (const [field, , ref] of refs) {
			const known = field === 'document_type_id' ? d.types : d.paths;
			if (ref && !known.some((x) => x.id === ref)) return validation(`actions.${field}`, 'unknown_reference'), null;
		}
		return {
			name,
			priority: typeof body.priority === 'number' ? body.priority : 0,
			enabled: body.enabled !== false,
			mode: body.mode === 'auto' ? 'auto' : 'suggest',
			confidence: typeof body.confidence === 'number' ? body.confidence : 0.8,
			conditions,
			actions
		};
	};
	const preview = (rule: Pick<Rule, 'name' | 'actions' | 'conditions' | 'mode'>, limit: number, ruleId: string | null) => {
		const docs = d.docs.filter((x) => x.trashed_at === null).sort((a, b) => b.created_at.localeCompare(a.created_at)).slice(0, limit);
		let matched = 0;
		let timedOut = 0;
		const items: unknown[] = [];
		for (const doc of docs) {
			const result = evalRule(rule, doc);
			if (result.timedOut) timedOut++;
			if (!result.met) continue;
			matched++;
			if (items.length >= 100) continue;
			const cands = candidates(rule, doc, result.matches[0]?.matched ?? '');
			items.push({
				document_id: doc.id,
				title: doc.title,
				matches: result.matches,
				suggestions: cands.map((c) => ({ kind: c.kind, value: c.value, confidence: 0.8, reason: c.reason }))
			});
		}
		return { rule_id: ruleId, mode: rule.mode, checked: docs.length, matched, timed_out: timedOut, truncated: false, items };
	};

	if (resource === 'rules') {
		if (!id && m === 'GET') {
			need('dms.rule.read');
			const items = admin.rules.filter((r) => !r.deleted).map(ruleOut);
			return send(200, host.page(items, ctx.query)), true;
		}
		if (!id && m === 'POST') {
			need('dms.rule.manage');
			const ok = checkRule(ctx.json);
			if (!ok) return true;
			if (admin.rules.some((r) => !r.deleted && r.name.toLowerCase() === ok.name.toLowerCase())) ctx.fail(409, 'conflict', 'Name bereits vergeben');
			const rule: Rule = { id: randomUUID(), ...ok, version: 1, created_at: now(), updated_at: now(), deleted: false };
			admin.rules.push(rule);
			return send(201, ruleOut(rule)), true;
		}
		if (id === 'preview' && m === 'POST') {
			need('dms.rule.manage');
			const ok = checkRule(ctx.json);
			if (!ok) return true;
			const limit = Math.min(500, Math.max(1, Number(ctx.json.limit ?? 100)));
			return send(200, preview(ok, limit, null)), true;
		}
		const rule = id ? admin.rules.find((r) => r.id === id && !r.deleted) : undefined;
		if (id && id !== 'preview') {
			if (m === 'GET' && !action) {
				need('dms.rule.read');
				if (!rule) ctx.fail(404, 'not_found', 'Nicht gefunden');
				return send(200, ruleOut(rule!)), true;
			}
			if (m === 'PATCH' && !action) {
				need('dms.rule.manage');
				if (!rule) ctx.fail(404, 'not_found', 'Nicht gefunden');
				const ok = checkRule({ ...rule, ...ctx.json });
				if (!ok) return true;
				const changed = JSON.stringify([ok.conditions, ok.actions, ok.mode, ok.confidence]) !== JSON.stringify([rule!.conditions, rule!.actions, rule!.mode, rule!.confidence]);
				Object.assign(rule!, ok, { updated_at: now(), version: rule!.version + (changed ? 1 : 0) });
				return send(200, ruleOut(rule!)), true;
			}
			if (m === 'DELETE' && !action) {
				need('dms.rule.manage');
				if (!rule) ctx.fail(404, 'not_found', 'Nicht gefunden');
				rule!.deleted = true;
				return send(204), true;
			}
			if (m === 'POST' && action === 'preview') {
				need('dms.rule.manage');
				if (!rule) ctx.fail(404, 'not_found', 'Nicht gefunden');
				return send(200, preview(rule!, Math.min(500, Math.max(1, Number(ctx.json.limit ?? 100))), rule!.id)), true;
			}
		}
		return false;
	}

	// ----- duplicates
	const dupOut = (x: Duplicate) => ({
		...x,
		document_title: d.docs.find((y) => y.id === x.document_id)?.title ?? '',
		duplicate_of_title: d.docs.find((y) => y.id === x.duplicate_of)?.title ?? '',
		decided_by: null
	});
	if (resource === 'duplicates') {
		if (!id && m === 'GET') {
			need('dms.document.read');
			const state = ctx.query.get('state') ?? 'open';
			const items = admin.duplicates.filter((x) => state === 'all' || x.state === state).map(dupOut);
			return send(200, host.page(items, ctx.query)), true;
		}
		if (id && action === 'resolve' && m === 'POST') {
			need('dms.document.update');
			const dup = admin.duplicates.find((x) => x.id === id);
			if (!dup) ctx.fail(404, 'not_found', 'Nicht gefunden');
			const state = ctx.json.state;
			if (state !== 'confirmed' && state !== 'dismissed') return validation('state', 'invalid');
			dup!.state = state;
			dup!.decided_at = now();
			return send(200, dupOut(dup!)), true;
		}
		return false;
	}

	// ----- retention, purge, deletion log
	if (resource === 'documents' && id && (action === 'retention' || action === 'purge')) {
		const doc = d.docs.find((x) => x.id === id);
		if (!doc) ctx.fail(404, 'not_found', 'Nicht gefunden');
		if (action === 'retention' && m === 'GET') return need('dms.document.read'), send(200, retentionOf(d, doc!)), true;
		if (action === 'retention' && m === 'PATCH') {
			need('dms.document.retention');
			const body = ctx.json;
			if (typeof body.legal_hold === 'boolean') doc!.legal_hold = body.legal_hold;
			if (typeof body.retention_until === 'string') {
				const current = retentionOf(d, doc!).retention_until;
				if (current && body.retention_until < current) return validation('retention_until', 'cannot_shorten');
				doc!.retention_override = body.retention_until;
			}
			return send(200, retentionOf(d, doc!)), true;
		}
		if (action === 'purge' && m === 'POST') {
			need('dms.document.purge');
			const r = retentionOf(d, doc!);
			if (r.blockers.length > 0) ctx.fail(409, r.blockers[0], 'Loeschen nicht moeglich');
			d.docs.splice(d.docs.indexOf(doc!), 1);
			admin.suggestions = admin.suggestions.filter((s) => s.document_id !== id);
			admin.duplicates = admin.duplicates.filter((x) => x.document_id !== id && x.duplicate_of !== id);
			admin.log.unshift({
				id: randomUUID(),
				document_id: doc!.id,
				asn: doc!.asn,
				document_type_id: doc!.document_type_id,
				doc_date: doc!.doc_date,
				retention_until: r.retention_until,
				original_sha256: doc!.file.sha256,
				original_size: doc!.file.bytes.length,
				file_count: 1,
				purged_at: now()
			});
			return send(200, { document_id: id, purged_at: now(), files_removed: 1, blobs_removed: 1 }), true;
		}
		return false;
	}
	if (resource === 'deletion-log' && m === 'GET') {
		need('dms.document.trash');
		return send(200, { items: admin.log.slice(0, 100).map((e) => ({ ...e, purged_by: null })) }), true;
	}

	// ----- integrity runs
	const headOf = () => createHash('sha256').update(`chain:${d.docs.length}:${admin.log.length}`).digest('hex');
	const runOut = (run: IntegrityRun) => {
		const ready = Date.now() >= run.readyAt;
		const bad = run.findings.length;
		return {
			id: run.id,
			state: !ready ? 'running' : bad > 0 ? 'failed' : 'passed',
			created_at: run.created_at,
			started_at: run.created_at,
			finished_at: ready ? new Date(run.readyAt).toISOString() : null,
			files_checked: ready ? run.checked : 0,
			files_bad: ready ? bad : 0,
			chain_entries: ready ? 42 : null,
			chain_ok: ready ? true : null,
			error_code: null,
			report: ready ? { findings: run.findings, truncated: false, chain: { entries: 42, ok: true, problem: null, broken_at_seq: null, head: headOf() } } : null
		};
	};
	if (resource === 'integrity-runs') {
		need('dms.integrity.run');
		if (!id && m === 'POST') {
			const findings = d.docs
				.filter((x) => x.text.includes(MOCK_TAMPER_MARKER))
				.map((x) => ({ document_id: x.id, role: 'original', problem: 'hash_mismatch' }));
			const run: IntegrityRun = { id: randomUUID(), created_at: now(), readyAt: Date.now() + ADMIN_JOB_MS, findings, checked: d.docs.length };
			admin.runs.unshift(run);
			return send(202, runOut(run)), true;
		}
		if (!id && m === 'GET') return send(200, { items: admin.runs.slice(0, 50).map(runOut) }), true;
		if (id && m === 'GET') {
			const run = admin.runs.find((x) => x.id === id);
			if (!run) ctx.fail(404, 'not_found', 'Nicht gefunden');
			return send(200, runOut(run!)), true;
		}
		return false;
	}

	// ----- exports
	const exportOut = (job: ExportJob) => {
		const ready = Date.now() >= job.readyAt;
		const state = !ready ? 'running' : job.failedCode ? 'failed' : 'done';
		return {
			id: job.id,
			state,
			params: job.params,
			created_at: job.created_at,
			finished_at: ready ? new Date(job.readyAt).toISOString() : null,
			document_count: state === 'done' ? job.docs.length : null,
			file_count: state === 'done' ? job.docs.length + 2 : null,
			size_bytes: state === 'done' ? job.zip.length : null,
			sha256: state === 'done' ? createHash('sha256').update(job.zip).digest('hex') : null,
			manifest_sha256: state === 'done' ? createHash('sha256').update('manifest' + job.id).digest('hex') : null,
			error_code: job.failedCode
		};
	};
	if (resource === 'exports') {
		need('dms.export.run');
		if (!id && m === 'POST') {
			const p = ctx.json;
			const docs = d.docs.filter(
				(x) =>
					x.trashed_at === null &&
					(typeof p.date_from !== 'string' || (x.doc_date !== null && x.doc_date >= p.date_from)) &&
					(typeof p.date_to !== 'string' || (x.doc_date !== null && x.doc_date <= p.date_to)) &&
					(typeof p.document_type_id !== 'string' || x.document_type_id === p.document_type_id)
			);
			const tampered = docs.some((x) => x.text.includes(MOCK_TAMPER_MARKER));
			const job: ExportJob = {
				id: randomUUID(),
				params: p,
				created_at: now(),
				readyAt: Date.now() + ADMIN_JOB_MS,
				failedCode: tampered ? 'integrity_failed' : null,
				docs,
				zip: Buffer.concat([Buffer.from('PK\x05\x06'), Buffer.alloc(18), Buffer.from(`mock-export:${docs.length}`)])
			};
			admin.exports.unshift(job);
			return send(202, exportOut(job)), true;
		}
		if (!id && m === 'GET') return send(200, { items: admin.exports.slice(0, 50).map(exportOut) }), true;
		const job = id ? admin.exports.find((x) => x.id === id) : undefined;
		if (id && m === 'GET' && !action) {
			if (!job) ctx.fail(404, 'not_found', 'Nicht gefunden');
			return send(200, exportOut(job!)), true;
		}
		if (id && m === 'GET' && action === 'file') {
			if (!job || exportOut(job).state !== 'done') ctx.fail(404, 'not_found', 'Nicht gefunden');
			return ctx.sendRaw(200, job!.zip, { 'content-type': 'application/zip', 'content-disposition': 'attachment; filename="export.zip"', 'cache-control': 'private, no-store' }), true;
		}
		return false;
	}
	return false;
}
