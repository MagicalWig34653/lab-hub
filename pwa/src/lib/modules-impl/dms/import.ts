import type { DmsImport, DmsImportInput, DmsImportReport } from '#lib/api/client';

/**
 * Logic of the Paperless import page (WP-PA2): the request built from the form, progress, report order and the text keys of
 * the backend codes. The token lives only in the form field until the request is built; nothing here stores or logs it.
 */
export interface ImportDraft {
	kind: DmsImport['source_kind'];
	mode: DmsImport['mode'];
	baseUrl: string;
	/** Write only: taken out of the draft when the request is built. */
	token: string;
	path: string;
	ocr: boolean;
}

export const emptyImportDraft = (): ImportDraft => ({ kind: 'api', mode: 'dry_run', baseUrl: '', token: '', path: '', ocr: true });

/** The request body; empties the token field in the same step, whatever happens to the request afterwards. */
export function takeImportInput(draft: ImportDraft): DmsImportInput {
	const token = draft.token.trim();
	draft.token = '';
	const source: DmsImportInput['source'] =
		draft.kind === 'api' ? { kind: 'api', base_url: draft.baseUrl.trim(), token } : { kind: 'export', path: draft.path.trim() };
	return { mode: draft.mode, source, options: { ocr: draft.ocr } };
}

export const isOpen = (run: DmsImport) => run.state === 'queued' || run.state === 'running';

/** Whole percent of the documents handled so far; `null` while the source has not told a total. */
export function percentDone(run: DmsImport): number | null {
	const { processed = 0, total } = run.progress;
	if (!total) return null;
	return Math.min(100, Math.floor((processed / total) * 100));
}

export const stateKeys = {
	queued: 'dms.import.state.queued',
	running: 'dms.import.state.running',
	done: 'dms.import.state.done',
	failed: 'dms.import.state.failed',
	cancelled: 'dms.import.state.cancelled'
} as const;

export const importErrorKeys: Record<string, string> = {
	import_root_missing: 'dms.import.error.import_root_missing',
	source_not_found: 'dms.import.error.source_not_found',
	manifest_missing: 'dms.import.error.manifest_missing',
	manifest_too_large: 'dms.import.error.manifest_too_large',
	manifest_invalid: 'dms.import.error.manifest_invalid',
	invalid_url: 'dms.import.error.invalid_url',
	scheme_not_allowed: 'dms.import.error.scheme_not_allowed',
	host_not_allowed: 'dms.import.error.host_not_allowed',
	source_auth_failed: 'dms.import.error.source_auth_failed',
	source_permission_denied: 'dms.import.error.source_permission_denied',
	source_api_version_unsupported: 'dms.import.error.source_api_version_unsupported',
	source_unreachable: 'dms.import.error.source_unreachable',
	source_tls_failed: 'dms.import.error.source_tls_failed',
	source_http_error: 'dms.import.error.source_http_error',
	source_response_invalid: 'dms.import.error.source_response_invalid',
	secret_key_missing: 'dms.import.error.secret_key_missing',
	secret_unreadable: 'dms.import.error.secret_unreadable',
	storage_quota_exceeded: 'dms.import.error.storage_quota_exceeded',
	module_disabled: 'dms.import.error.module_disabled',
	worker_lost: 'dms.import.error.worker_lost',
	import_failed: 'dms.import.error.import_failed'
};

/** Text key for a refused start or cancel; `null` = use the general error text. */
export function errorKeyFor(status: number, fields: { field: string; code: string }[], action: 'start' | 'cancel'): string | null {
	if (status === 409) return action === 'start' ? 'dms.import.error.already_open' : 'dms.import.error.not_cancellable';
	if (status !== 422 || !fields[0]) return null;
	const { field, code } = fields[0];
	if (code in importErrorKeys) return importErrorKeys[code];
	if (field === 'source.path') return 'dms.import.error.path_invalid';
	if (field === 'source.base_url') return code === 'required' ? 'dms.import.error.base_url_required' : 'dms.import.error.invalid_url';
	if (field === 'source.token') return 'dms.import.error.token_required';
	return null;
}

/** Counters of the report in reading order. Others the backend adds later are shown with their raw name at the end. */
export const countKeys: Record<string, string> = {
	documents_seen: 'dms.import.count.documents_seen',
	documents_would_import: 'dms.import.count.documents_would_import',
	documents_imported: 'dms.import.count.documents_imported',
	documents_skipped_existing: 'dms.import.count.documents_skipped_existing',
	documents_skipped: 'dms.import.count.documents_skipped',
	documents_failed: 'dms.import.count.documents_failed',
	documents_hash_exists: 'dms.import.count.documents_hash_exists',
	documents_in_trash: 'dms.import.count.documents_in_trash',
	versions_skipped: 'dms.import.count.versions_skipped',
	files_original: 'dms.import.count.files_original',
	files_archive: 'dms.import.count.files_archive',
	files_checksum_verified: 'dms.import.count.files_checksum_verified',
	files_without_checksum: 'dms.import.count.files_without_checksum',
	archives_without_checksum: 'dms.import.count.archives_without_checksum',
	notes_total: 'dms.import.count.notes_total',
	notes_imported: 'dms.import.count.notes_imported',
	asn_assigned: 'dms.import.count.asn_assigned',
	asn_collisions: 'dms.import.count.asn_collisions',
	correspondents_created: 'dms.import.count.correspondents_created',
	correspondents_would_create: 'dms.import.count.correspondents_would_create',
	correspondents_matched: 'dms.import.count.correspondents_matched',
	correspondents_merged: 'dms.import.count.correspondents_merged',
	correspondents_existing: 'dms.import.count.correspondents_existing',
	correspondents_possible_duplicates: 'dms.import.count.correspondents_possible_duplicates',
	types_created: 'dms.import.count.types_created',
	types_would_create: 'dms.import.count.types_would_create',
	types_matched: 'dms.import.count.types_matched',
	types_merged: 'dms.import.count.types_merged',
	types_existing: 'dms.import.count.types_existing',
	tags_created: 'dms.import.count.tags_created',
	tags_would_create: 'dms.import.count.tags_would_create',
	tags_matched: 'dms.import.count.tags_matched',
	tags_merged: 'dms.import.count.tags_merged',
	tags_existing: 'dms.import.count.tags_existing',
	tags_similar: 'dms.import.count.tags_similar',
	paths_created: 'dms.import.count.paths_created',
	paths_would_create: 'dms.import.count.paths_would_create',
	paths_matched: 'dms.import.count.paths_matched',
	paths_merged: 'dms.import.count.paths_merged',
	paths_existing: 'dms.import.count.paths_existing',
	paths_untranslatable: 'dms.import.count.paths_untranslatable',
	fields_created: 'dms.import.count.fields_created',
	fields_would_create: 'dms.import.count.fields_would_create',
	fields_matched: 'dms.import.count.fields_matched',
	fields_merged: 'dms.import.count.fields_merged',
	fields_existing: 'dms.import.count.fields_existing',
	fields_conflict: 'dms.import.count.fields_conflict',
	fields_unsupported: 'dms.import.count.fields_unsupported',
	field_values_dropped: 'dms.import.count.field_values_dropped',
	documents_reference_dropped: 'dms.import.count.documents_reference_dropped'
};

/** Counters shown elsewhere in the report (archive numbers, rights) or only mirroring the findings. */
const internalCount = (name: string) => name.startsWith('findings_') || ['asn_max_seen', 'owners_seen', 'source_users', 'source_groups', 'processed', 'total'].includes(name);

export function reportCounts(report: DmsImportReport): { name: string; key: string | null; value: number }[] {
	const counts = report.counts ?? {};
	const order = Object.keys(countKeys);
	const rank = (name: string) => (name in countKeys ? order.indexOf(name) : order.length);
	return Object.keys(counts)
		.filter((name) => !internalCount(name))
		.sort((a, b) => rank(a) - rank(b) || a.localeCompare(b))
		.map((name) => ({ name, key: countKeys[name] ?? null, value: counts[name] }));
}

export const findingKeys: Record<string, string> = {
	asn_collision: 'dms.import.finding.asn_collision',
	file_without_checksum: 'dms.import.finding.file_without_checksum',
	file_missing: 'dms.import.finding.file_missing',
	checksum_mismatch: 'dms.import.finding.checksum_mismatch',
	archive_checksum_mismatch: 'dms.import.finding.archive_checksum_mismatch',
	archive_missing: 'dms.import.finding.archive_missing',
	archive_too_large: 'dms.import.finding.archive_too_large',
	archive_unsupported: 'dms.import.finding.archive_unsupported',
	document_versions_skipped: 'dms.import.finding.document_versions_skipped',
	document_in_trash_skipped: 'dms.import.finding.document_in_trash_skipped',
	unsupported_type: 'dms.import.finding.unsupported_type',
	file_too_large: 'dms.import.finding.file_too_large',
	hash_exists: 'dms.import.finding.hash_exists',
	duplicate_hash_imported: 'dms.import.finding.duplicate_hash_imported',
	contact_possible_duplicate: 'dms.import.finding.contact_possible_duplicate',
	reference_matched_by_name: 'dms.import.finding.reference_matched_by_name',
	tag_similar: 'dms.import.finding.tag_similar',
	storage_path_untranslatable: 'dms.import.finding.storage_path_untranslatable',
	custom_field_unsupported: 'dms.import.finding.custom_field_unsupported',
	custom_field_type_conflict: 'dms.import.finding.custom_field_type_conflict',
	custom_field_options_invalid: 'dms.import.finding.custom_field_options_invalid',
	custom_field_value_dropped: 'dms.import.finding.custom_field_value_dropped',
	monetary_currency_dropped: 'dms.import.finding.monetary_currency_dropped',
	reference_unknown: 'dms.import.finding.reference_unknown',
	reference_not_visible: 'dms.import.finding.reference_not_visible',
	text_truncated: 'dms.import.finding.text_truncated',
	title_truncated: 'dms.import.finding.title_truncated',
	document_failed: 'dms.import.finding.document_failed'
};

/** Findings that mean something was not taken over (or not completely): a document, a file, a value or a reference. */
const PROBLEMS = new Set([
	'duplicate_hash_imported',
	'custom_field_value_dropped',
	'reference_unknown',
	'reference_not_visible',
	'text_truncated',
	'title_truncated',
	'file_missing',
	'checksum_mismatch',
	'archive_checksum_mismatch',
	'archive_missing',
	'archive_too_large',
	'archive_unsupported',
	'unsupported_type',
	'file_too_large',
	'document_failed'
]);

export function reportFindings(report: DmsImportReport) {
	return Object.entries(report.findings ?? {})
		.map(([code, f]) => ({ code, key: findingKeys[code] ?? null, problem: PROBLEMS.has(code), total: f.total, items: f.items }))
		.sort((a, b) => Number(b.problem) - Number(a.problem) || a.code.localeCompare(b.code));
}

export const refKeys: Record<string, string> = {
	document: 'dms.import.ref.document',
	correspondent: 'dms.import.ref.correspondent',
	document_type: 'dms.import.ref.document_type',
	type: 'dms.import.ref.document_type',
	tag: 'dms.import.ref.tag',
	storage_path: 'dms.import.ref.storage_path',
	path: 'dms.import.ref.storage_path',
	custom_field: 'dms.import.ref.custom_field',
	field: 'dms.import.ref.custom_field'
};

/**
 * The backend writes `kind:id`, a document with the reference it lost as `document:7/type:3`, and a pair of similar tags as
 * `tag:1-2`. `null` = unknown shape, shown as written.
 */
export function refParts(ref: string): { key: string; id: string }[] | null {
	const parts: { key: string; id: string }[] = [];
	for (const piece of ref.split('/')) {
		const match = /^([a-z_]+):(\d+(?:-\d+)*)$/.exec(piece);
		if (!match || !(match[1] in refKeys)) return null;
		for (const id of match[2].split('-')) parts.push({ key: refKeys[match[1]], id });
	}
	return parts;
}

/**
 * Whether a report has figures worth showing. A run that failed or was cancelled before reading anything has none, although
 * the backend always adds `documents_imported: 0` to an import.
 */
export function reportHasData(report: DmsImportReport): boolean {
	return report.state === 'done' || reportFindings(report).length > 0 || reportCounts(report).some((c) => c.value > 0);
}

export const targetKeys = {
	correspondent: 'dms.import.ref.correspondent',
	document_type: 'dms.import.ref.document_type',
	tag: 'dms.import.ref.tag',
	storage_path: 'dms.import.ref.storage_path'
} as const;
