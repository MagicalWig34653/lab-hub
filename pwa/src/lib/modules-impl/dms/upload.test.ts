import { describe, expect, it, vi } from 'vitest';
import { ApiError, type DmsDocument, type DmsProcessing } from '#lib/api/client';
import { UploadQueue, classifyUploadError, type UploadDeps } from './upload.svelte';

const doc = (over: Partial<DmsDocument> & Record<string, unknown> = {}): DmsDocument => ({
	id: crypto.randomUUID(),
	title: 't',
	received_at: '2026-01-01T00:00:00Z',
	status: 'needs_review',
	created_at: '2026-01-01T00:00:00Z',
	updated_at: '2026-01-01T00:00:00Z',
	rev: 1,
	...over
});
const proc = (phase: DmsProcessing['phase'], over: Partial<DmsProcessing> = {}): DmsProcessing => ({
	document_id: 'd',
	state: 'none',
	phase,
	steps: [],
	has_archive: false,
	...over
});
const file = (name: string) => new File(['x'], name);
const settle = () => new Promise((r) => setTimeout(r, 30));

function queue(overrides: Partial<UploadDeps>) {
	return new UploadQueue({ upload: async () => doc(), fetchProcessing: async () => proc('done'), pollMs: 5, interruptedRetryMs: 1, ...overrides });
}

describe('classifyUploadError', () => {
	it('maps contract errors to failure kinds', () => {
		expect(classifyUploadError(new ApiError(415, 'unsupported_media_type'))).toBe('unsupported');
		expect(classifyUploadError(new ApiError(413, 'payload_too_large'))).toBe('too_large');
		expect(classifyUploadError(new ApiError(413, 'storage_quota_exceeded'))).toBe('quota');
		expect(classifyUploadError(new ApiError(500, 'internal_error'))).toBe('other');
		expect(classifyUploadError(new Error('x'))).toBe('other');
	});
});

describe('UploadQueue (AK-F4-1/4)', () => {
	it('uploads several files, reports progress and finishes as done', async () => {
		const upload = vi.fn(async (_f: File, o: { onProgress: (f: number) => void }) => {
			o.onProgress(0.5);
			return doc();
		});
		const q = queue({ upload });
		q.add([file('a.pdf'), file('b.pdf'), file('c.pdf')]);
		await settle();
		expect(upload).toHaveBeenCalledTimes(3);
		expect(q.items.map((i) => i.state)).toEqual(['done', 'done', 'done']);
		expect(q.busy).toBe(false);
	});

	it('a document without an ingest item is done at once, without polling', async () => {
		const fetchProcessing = vi.fn(async () => proc('done'));
		const q = queue({ upload: async () => doc({ status: 'processing' }), fetchProcessing });
		q.add([file('a.pdf')]);
		await settle();
		expect(q.items[0].state).toBe('done');
		expect(fetchProcessing).not.toHaveBeenCalled();
	});

	it('polls the processing status until the phase is done', async () => {
		let calls = 0;
		const settled: string[] = [];
		const q = queue({
			upload: async () => doc({ id: 'p', status: 'processing', ingest_item_id: 'i' }),
			fetchProcessing: async () => proc(++calls < 3 ? (calls === 1 ? 'queued' : 'processing') : 'done'),
			onSettled: (d) => settled.push(d.id)
		});
		q.add([file('a.pdf')]);
		await new Promise((r) => setTimeout(r, 100));
		expect(q.items[0].state).toBe('done');
		expect(calls).toBe(3);
		expect(settled.length).toBeGreaterThanOrEqual(2);
	});

	it('keeps polling through a transient error and through the retrying phase', async () => {
		const answers: (() => Promise<DmsProcessing>)[] = [
			async () => {
				throw new ApiError(0, 'network_error');
			},
			async () => proc('retrying'),
			async () => proc('done')
		];
		let i = 0;
		const q = queue({ upload: async () => doc({ ingest_item_id: 'i' }), fetchProcessing: () => answers[Math.min(i++, 2)]() });
		q.add([file('a.pdf')]);
		await new Promise((r) => setTimeout(r, 100));
		expect(q.items[0].state).toBe('done');
	});

	it('phase failed is a quarantine with the error code; retry re-queues and ends done', async () => {
		let retried = 0;
		let phase: DmsProcessing['phase'] = 'failed';
		const q = queue({
			upload: async () => doc({ id: 'q', ingest_item_id: 'i' }),
			fetchProcessing: async () => (phase === 'failed' ? proc('failed', { error_code: 'pdf_encrypted' }) : proc(phase)),
			retryProcessing: async () => {
				retried++;
				phase = 'done';
				return proc('queued');
			}
		});
		q.add([file('a.pdf')]);
		await settle();
		expect(q.items[0].state).toBe('quarantine');
		expect(q.items[0].processing?.error_code).toBe('pdf_encrypted');
		await q.retryQuarantine(q.items[0].id);
		expect(retried).toBe(1);
		expect(q.items[0].state).toBe('done');
	});

	it('repeats an upload_interrupted upload automatically with the same idempotency key', async () => {
		const keys: string[] = [];
		const q = queue({
			upload: async (_f, o) => {
				keys.push(o.idempotencyKey);
				if (keys.length < 3) throw new ApiError(409, 'upload_interrupted');
				return doc();
			}
		});
		q.add([file('a.pdf')]);
		await settle();
		expect(q.items[0].state).toBe('done');
		expect(keys).toHaveLength(3);
		expect(new Set(keys).size).toBe(1);
	});

	it('gives up after the allowed number of interrupted attempts', async () => {
		const upload = vi.fn(async (): Promise<DmsDocument> => {
			throw new ApiError(409, 'upload_interrupted');
		});
		const q = queue({ upload, maxInterruptedRetries: 2 });
		q.add([file('a.pdf')]);
		await settle();
		expect(upload).toHaveBeenCalledTimes(3);
		expect(q.items[0].state).toBe('error');
		expect(q.items[0].failure).toBe('other');
	});

	it('shows a duplicate hint, a quarantine, and keeps error kinds', async () => {
		const answers = [
			async () => doc({ duplicates: ['other'] }),
			async () => doc({ ingest_item_id: 'i' }),
			async (): Promise<DmsDocument> => {
				throw new ApiError(415, 'unsupported_media_type');
			},
			async (): Promise<DmsDocument> => {
				throw new ApiError(413, 'payload_too_large');
			},
			async (): Promise<DmsDocument> => {
				throw new ApiError(413, 'storage_quota_exceeded');
			}
		];
		let i = 0;
		const q = queue({
			upload: () => answers[i++](),
			fetchProcessing: async () => proc('failed', { error_code: 'pdf_encrypted' }),
			concurrency: 1
		});
		q.add([file('1'), file('2'), file('3'), file('4'), file('5')]);
		await settle();
		expect(q.items.map((x) => x.state)).toEqual(['duplicate', 'quarantine', 'error', 'error', 'error']);
		expect(q.items.map((x) => x.failure)).toEqual([undefined, undefined, 'unsupported', 'too_large', 'quota']);
	});

	it('retry reuses the idempotency key', async () => {
		const keys: string[] = [];
		let fail = true;
		const q = queue({
			upload: async (_f, o) => {
				keys.push(o.idempotencyKey);
				if (fail) throw new ApiError(0, 'network_error');
				return doc();
			}
		});
		q.add([file('a.pdf')]);
		await settle();
		expect(q.items[0].state).toBe('error');
		fail = false;
		q.retry(q.items[0].id);
		await settle();
		expect(q.items[0].state).toBe('done');
		expect(keys[0]).toBe(keys[1]);
	});
});
