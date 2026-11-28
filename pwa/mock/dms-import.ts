import { randomUUID } from 'node:crypto';
import type { DmsContext, TenantData } from './dms.ts';

/**
 * Mock of the WP-D6 import routes (contracts/openapi.yaml) and the note list. Test double with synthetic data only.
 *
 * Behaviour that tests rely on:
 * - A run walks over 12 invented documents, one per `STEP_MS`; an address ending in `/slow` takes `SLOW_STEP_MS`.
 * - An address ending in `/fail-auth` fails with `source_auth_failed`; the host `intern.example.org` is `host_not_allowed`.
 * - The token is only checked for presence and thrown away; it is stored nowhere.
 * - A running run that was asked to cancel ends after one further step, keeping the documents done so far.
 */
export const IMPORT_TOTAL = 12;
const STEP_MS = 250;
const SLOW_STEP_MS = 1200;
const QUEUED_MS = 150;

export interface ImportRun {
	id: string;
	source_kind: 'api' | 'export';
	source_key: string;
	mode: 'dry_run' | 'import';
	config: Record<string, string>;
	created_at: string;
	startedMs: number;
	stepMs: number;
	failCode: string | null;
	cancelAtMs: number | null;
}

export interface MockNote {
	id: string;
	body: string;
	noted_at: string | null;
	origin: string | null;
	created_at: string;
}

/** The state of a run is derived from the clock, like the other mock jobs. */
function snapshot(run: ImportRun) {
	const now = Date.now();
	const end = (t: number) => Math.min(IMPORT_TOTAL, Math.max(0, Math.floor((t - run.startedMs) / run.stepMs)));
	let state: 'queued' | 'running' | 'done' | 'failed' | 'cancelled';
	let processed = end(now);
	let finished: number | null = null;
	if (run.failCode && now - run.startedMs >= run.stepMs) {
		state = 'failed';
		processed = 0;
		finished = run.startedMs + run.stepMs;
	} else if (run.cancelAtMs !== null && now >= run.cancelAtMs && end(run.cancelAtMs) < IMPORT_TOTAL) {
		state = 'cancelled';
		processed = end(run.cancelAtMs);
		finished = run.cancelAtMs;
	} else if (processed >= IMPORT_TOTAL) {
		state = 'done';
		finished = run.startedMs + IMPORT_TOTAL * run.stepMs;
	} else state = now - run.startedMs < QUEUED_MS ? 'queued' : 'running';
	return { state, processed, finished };
}

function out(run: ImportRun) {
	const { state, processed, finished } = snapshot(run);
	return {
		id: run.id,
		source_kind: run.source_kind,
		mode: run.mode,
		state,
		cancel_requested: run.cancelAtMs !== null,
		config: run.config,
		has_secret: run.source_kind === 'api' && finished === null,
		progress: state === 'queued' ? {} : { processed, total: IMPORT_TOTAL, documents_seen: processed },
		error_code: state === 'failed' ? run.failCode : null,
		requested_by: '00000000-0000-0000-0000-000000000001',
		created_at: run.created_at,
		started_at: run.created_at,
		finished_at: finished === null ? null : new Date(finished).toISOString()
	};
}

function report(run: ImportRun) {
	const { state, processed } = snapshot(run);
	const done = Math.max(0, processed - (state === 'done' ? 1 : 0));
	const failed = state === 'failed';
	// like the backend: an import always counts `documents_imported`, even if the run failed before reading anything
	const nothing: Record<string, number> = run.mode === 'import' ? { documents_imported: 0 } : {};
	const counts: Record<string, number> = failed
		? nothing
		: {
				documents_seen: processed,
				[run.mode === 'import' ? 'documents_imported' : 'documents_would_import']: done,
				documents_skipped: state === 'done' ? 1 : 0,
				files_original: done,
				files_checksum_verified: done,
				notes_total: 2,
				[run.mode === 'import' ? 'tags_created' : 'tags_would_create']: 3,
				asn_max_seen: 4711,
				findings_checksum_mismatch: 1
			};
	return {
		format: 'labhub-paperless-import-report/1',
		mode: run.mode,
		source_kind: run.source_kind,
		state,
		...(failed ? { error_code: run.failCode } : {}),
		counts,
		findings: failed
			? {}
			: {
					tag_similar: { total: 1, items: [{ ref: 'tag:2', detail: 'Steuer / Steuern' }] },
					checksum_mismatch: { total: 1, items: [{ ref: 'document:7', detail: 'original' }] }
				},
		asn: { max_seen: failed ? 0 : 4711, collisions: 0, counter_value: run.mode === 'import' ? 4711 : null },
		rights: {
			imported: false,
			note_code: 'rights_not_imported',
			visibility_note_code: run.source_kind === 'api' ? 'api_visible_to_token_user_only' : 'export_complete',
			owners_seen: 2,
			source_users: 2,
			source_groups: 1
		},
		rule_suggestions: failed ? [] : [{ target_kind: 'correspondent', target_name: 'Musterversorger', algorithm: 'literal', match: 'Musterversorger', case_insensitive: true, translatable: true }]
	};
}

export function handleImports(d: TenantData, ctx: DmsContext): boolean {
	const [, resource, id, action] = ctx.parts;
	if (resource !== 'imports') return false;
	const m = ctx.method;
	const need = (permission: string) => {
		if (!ctx.permissions.includes(permission)) ctx.fail(403, 'forbidden', 'Keine Berechtigung');
	};
	const invalid = (field: string, code: string) => {
		ctx.send(422, { type: 'about:blank', title: 'Eingabe ungueltig', status: 422, code: 'validation_failed', request_id: randomUUID(), errors: [{ field, code }] });
		return true;
	};
	if (m === 'GET' && !id) return need('dms.import.read'), ctx.send(200, { items: d.imports.map(out) }), true;
	if (m === 'POST' && !id) {
		need('dms.import.manage');
		const { mode, source } = ctx.json as { mode?: string; source?: Record<string, string> };
		if (mode !== 'dry_run' && mode !== 'import') return invalid('mode', 'invalid');
		if (!source || (source.kind !== 'api' && source.kind !== 'export')) return invalid('source.kind', 'invalid');
		let key: string;
		let config: Record<string, string>;
		let failCode: string | null = null;
		if (source.kind === 'export') {
			if (!source.path) return invalid('source.path', 'required');
			if (source.path.includes('..') || source.path.startsWith('/')) return invalid('source.path', 'invalid');
			key = `export:${source.path.toLowerCase()}`;
			config = { path: source.path };
		} else {
			if (!source.base_url) return invalid('source.base_url', 'required');
			if (!/^https:\/\/[a-z0-9.-]+(\/[A-Za-z0-9._/-]*)?$/.test(source.base_url)) return invalid('source.base_url', 'invalid_url');
			if (new URL(source.base_url).hostname === 'intern.example.org') return invalid('source.base_url', 'host_not_allowed');
			if (!source.token) return invalid('source.token', 'required');
			key = `api:${source.base_url}`;
			config = { base_url: source.base_url };
			if (source.base_url.endsWith('/fail-auth')) failCode = 'source_auth_failed';
		}
		if (d.imports.some((x) => x.source_key === key && ['queued', 'running'].includes(snapshot(x).state))) ctx.fail(409, 'conflict', 'Lauf offen');
		const run: ImportRun = {
			id: randomUUID(),
			source_kind: source.kind,
			source_key: key,
			mode,
			config,
			created_at: new Date().toISOString(),
			startedMs: Date.now(),
			stepMs: config.base_url?.endsWith('/slow') ? SLOW_STEP_MS : STEP_MS,
			failCode,
			cancelAtMs: null
		};
		d.imports.unshift(run);
		return ctx.send(202, out(run)), true;
	}
	const run = d.imports.find((x) => x.id === id);
	if (!run) ctx.fail(404, 'not_found', 'Nicht gefunden');
	if (m === 'GET' && !action) return need('dms.import.read'), ctx.send(200, out(run!)), true;
	if (m === 'GET' && action === 'report') {
		need('dms.import.read');
		if (snapshot(run!).finished === null) ctx.fail(404, 'not_found', 'Nicht gefunden');
		return (
			ctx.sendRaw(200, Buffer.from(JSON.stringify(report(run!))), {
				'content-type': 'application/json',
				'content-disposition': `attachment; filename="paperless-import-report-${run!.id.slice(0, 8)}.json"`,
				'cache-control': 'no-store',
				'x-content-type-options': 'nosniff'
			}),
			true
		);
	}
	if (m === 'POST' && action === 'cancel') {
		need('dms.import.manage');
		if (snapshot(run!).finished !== null) ctx.fail(409, 'conflict', 'Lauf beendet');
		run!.cancelAtMs ??= Date.now() + run!.stepMs;
		return ctx.send(200, out(run!)), true;
	}
	return false;
}
