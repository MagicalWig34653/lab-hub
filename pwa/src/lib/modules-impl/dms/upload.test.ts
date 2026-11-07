import { describe, expect, it, vi } from 'vitest';
import { ApiError, type DmsDocument } from '#lib/api/client';
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
const file = (name: string) => new File(['x'], name);
const settle = () => new Promise((r) => setTimeout(r, 30));

function queue(overrides: Partial<UploadDeps>) {
	return new UploadQueue({ upload: async () => doc(), fetchDocument: async () => doc(), pollMs: 5, ...overrides });
}

describe('classifyUploadError', () => {
	it('maps contract errors to failure kinds', () => {
		expect(classifyUploadError(new ApiError(415, 'unsupported_media_type'))).toBe('unsupported');
		expect(classifyUploadError(new ApiError(413, 'payload_too_large'))).toBe('too_large');
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

	it('polls a processing document until it is processed', async () => {
		let calls = 0;
		const settled: string[] = [];
		const q = queue({
			upload: async () => doc({ id: 'p', status: 'processing' }),
			fetchDocument: async () => (++calls < 3 ? doc({ id: 'p', status: 'processing' }) : doc({ id: 'p', status: 'needs_review' })),
			onSettled: (d) => settled.push(d.status)
		});
		q.add([file('a.pdf')]);
		await new Promise((r) => setTimeout(r, 80));
		expect(q.items[0].state).toBe('done');
		expect(settled.at(-1)).toBe('needs_review');
	});

	it('shows a duplicate hint, a quarantine, and keeps error kinds', async () => {
		const answers = [
			async () => doc({ duplicates: ['other'] }),
			async () => doc({ status: 'processing', ingest_state: 'failed_permanent' }),
			async (): Promise<DmsDocument> => {
				throw new ApiError(415, 'unsupported_media_type');
			},
			async (): Promise<DmsDocument> => {
				throw new ApiError(413, 'payload_too_large');
			}
		];
		let i = 0;
		const q = queue({ upload: () => answers[i++]() });
		q.add([file('1'), file('2'), file('3'), file('4')]);
		await settle();
		expect(q.items.map((x) => x.state)).toEqual(['duplicate', 'quarantine', 'error', 'error']);
		expect(q.items.map((x) => x.failure)).toEqual([undefined, undefined, 'unsupported', 'too_large']);
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
