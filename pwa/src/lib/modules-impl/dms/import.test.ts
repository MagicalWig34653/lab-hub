import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import type { DmsImport, DmsImportReport } from '#lib/api/client';
import { dmsManifest } from './manifest';
import {
	emptyImportDraft,
	errorKeyFor,
	findingKeys,
	importErrorKeys,
	isOpen,
	percentDone,
	refParts,
	reportHasData,
	reportCounts,
	reportFindings,
	takeImportInput
} from './import';

const contract = readFileSync(join(process.cwd(), '..', 'contracts', 'openapi.yaml'), 'utf8');
/** The comma separated code list that follows `marker` in the contract text. */
const codesAfter = (marker: string) => {
	const line = contract.split('\n').find((l) => l.includes(marker));
	expect(line, marker).toBeTruthy();
	return line!
		.slice(line!.indexOf(marker) + marker.length)
		.replace(/".*$/, '')
		.split(',')
		.map((c) => c.trim())
		.filter((c) => /^[a-z_]+$/.test(c));
};

const run = (over: Partial<DmsImport>): DmsImport => ({
	id: '00000000-0000-0000-0000-000000000001',
	source_kind: 'api',
	mode: 'dry_run',
	state: 'running',
	cancel_requested: false,
	config: {},
	has_secret: true,
	progress: {},
	requested_by: '00000000-0000-0000-0000-000000000002',
	created_at: '2026-11-28T00:00:00Z',
	...over
});

describe('AK-PA2-1 request from the form', () => {
	it('builds the API request and empties the token field in the same step', () => {
		const draft = { ...emptyImportDraft(), baseUrl: '  https://paperless.example.org/ ', token: '  tok-123 ' };
		const input = takeImportInput(draft);
		expect(input).toEqual({
			mode: 'dry_run',
			source: { kind: 'api', base_url: 'https://paperless.example.org/', token: 'tok-123' },
			options: { ocr: true }
		});
		expect(draft.token).toBe('');
		expect(draft.baseUrl).toContain('paperless.example.org');
	});

	it('the export source never carries a token, and a typed token is dropped', () => {
		const draft = { ...emptyImportDraft(), kind: 'export' as const, path: ' paperless-export ', token: 'tok-123', mode: 'import' as const, ocr: false };
		expect(takeImportInput(draft)).toEqual({ mode: 'import', source: { kind: 'export', path: 'paperless-export' }, options: { ocr: false } });
		expect(draft.token).toBe('');
	});

	it('starts with the REST API and the dry run (the choice that writes nothing)', () => {
		expect(emptyImportDraft()).toMatchObject({ kind: 'api', mode: 'dry_run', token: '', baseUrl: '', path: '' });
	});
});

describe('AK-PA2-1 progress and state', () => {
	it('queued and running runs are open, finished ones are not', () => {
		expect(['queued', 'running', 'done', 'failed', 'cancelled'].map((state) => isOpen(run({ state: state as DmsImport['state'] })))).toEqual([true, true, false, false, false]);
	});

	it('percent is unknown without a total and never above 100', () => {
		expect(percentDone(run({ progress: {} }))).toBeNull();
		expect(percentDone(run({ progress: { processed: 3, total: 0 } }))).toBeNull();
		expect(percentDone(run({ progress: { processed: 3, total: 8 } }))).toBe(37);
		expect(percentDone(run({ progress: { processed: 12, total: 8 } }))).toBe(100);
		expect(percentDone(run({ progress: { total: 8 } }))).toBe(0);
	});
});

describe('AK-PA2-1 report and error texts', () => {
	const report = {
		counts: { documents_seen: 10, documents_would_import: 10, notes_total: 2, findings_asn_collision: 1, asn_max_seen: 7, owners_seen: 1, tags_would_create: 3, something_new: 4 }
	} as unknown as DmsImportReport;

	it('lists known counters in a fixed order, unknown ones last, internal ones never', () => {
		expect(reportCounts(report).map((c) => [c.name, c.value, c.key !== null])).toEqual([
			['documents_seen', 10, true],
			['documents_would_import', 10, true],
			['notes_total', 2, true],
			['tags_would_create', 3, true],
			['something_new', 4, false]
		]);
	});

	it('orders findings: problems before notes, then by code', () => {
		const findings = reportFindings({
			findings: {
				tag_similar: { total: 1, items: [{ ref: 'tag:1' }] },
				checksum_mismatch: { total: 2, items: [{ ref: 'document:4', detail: 'x' }] },
				asn_collision: { total: 1, items: [{ ref: 'document:2' }] },
				brand_new_code: { total: 1, items: [{ ref: 'document:3' }] }
			}
		} as unknown as DmsImportReport);
		expect(findings.map((f) => [f.code, f.problem, f.key !== null])).toEqual([
			['checksum_mismatch', true, true],
			['asn_collision', false, true],
			['brand_new_code', false, false],
			['tag_similar', false, true]
		]);
	});

	it('names every part of a combined reference of the backend', () => {
		expect(refParts('document:7')).toEqual([{ key: 'dms.import.ref.document', id: '7' }]);
		expect(refParts('document:7/type:3')).toEqual([
			{ key: 'dms.import.ref.document', id: '7' },
			{ key: 'dms.import.ref.document_type', id: '3' }
		]);
		expect(refParts('document:7/field:2')?.map((p) => p.key)).toEqual(['dms.import.ref.document', 'dms.import.ref.custom_field']);
		// two similar tags share one reference
		expect(refParts('tag:1-2')).toEqual([
			{ key: 'dms.import.ref.tag', id: '1' },
			{ key: 'dms.import.ref.tag', id: '2' }
		]);
		expect(refParts('something else')).toBeNull();
		expect(refParts('document:7/unknown:1')).toBeNull();
	});

	it('counts everything that loses a document, a value or a reference as a problem', () => {
		const codes = ['duplicate_hash_imported', 'custom_field_value_dropped', 'reference_unknown', 'reference_not_visible', 'text_truncated', 'title_truncated', 'hash_exists', 'tag_similar'];
		const findings = reportFindings({ findings: Object.fromEntries(codes.map((c) => [c, { total: 1, items: [] }])) } as unknown as DmsImportReport);
		expect(findings.filter((f) => !f.problem).map((f) => f.code)).toEqual(['hash_exists', 'tag_similar']);
	});

	it('a failed run that read nothing has no figures, even with the zero the backend always adds to an import', () => {
		const empty = (state: string, counts: Record<string, number>) => ({ state, counts, findings: {} }) as unknown as DmsImportReport;
		expect(reportHasData(empty('failed', { documents_imported: 0 }))).toBe(false);
		expect(reportHasData(empty('cancelled', {}))).toBe(false);
		expect(reportHasData(empty('failed', { documents_seen: 2, documents_imported: 0 }))).toBe(true);
		expect(reportHasData(empty('done', { documents_imported: 0 }))).toBe(true);
	});

	it('has a text for every run error code and every finding code of the contract', () => {
		const errors = codesAfter('description: "bei failed:');
		const findings = codesAfter('Codes u. a. asn_collision'.replace(' asn_collision', ''));
		expect(errors.length).toBeGreaterThan(15);
		expect(findings.length).toBeGreaterThan(15);
		expect(errors.filter((c) => !(c in importErrorKeys))).toEqual([]);
		expect(findings.filter((c) => !(c in findingKeys))).toEqual([]);
		for (const key of [...Object.values(importErrorKeys), ...Object.values(findingKeys)]) {
			expect(dmsManifest.messages.de[key], key).toBeTruthy();
			expect(dmsManifest.messages.en[key], key).toBeTruthy();
		}
	});

	it('picks the field code of a rejected request, else the conflict text', () => {
		expect(errorKeyFor(422, [{ field: 'source.base_url', code: 'host_not_allowed' }], 'start')).toBe(importErrorKeys.host_not_allowed);
		expect(errorKeyFor(422, [{ field: 'source.path', code: 'invalid' }], 'start')).toBe('dms.import.error.path_invalid');
		expect(errorKeyFor(422, [{ field: 'source.base_url', code: 'required' }], 'start')).toBe('dms.import.error.base_url_required');
		expect(errorKeyFor(422, [{ field: 'source.token', code: 'required' }], 'start')).toBe('dms.import.error.token_required');
		expect(errorKeyFor(409, [], 'start')).toBe('dms.import.error.already_open');
		expect(errorKeyFor(409, [], 'cancel')).toBe('dms.import.error.not_cancellable');
		expect(errorKeyFor(500, [], 'start')).toBeNull();
	});
});
