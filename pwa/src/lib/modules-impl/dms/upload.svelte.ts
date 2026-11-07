import { ApiError, type DmsDocument, type DmsProcessing } from '#lib/api/client';

export type UploadState = 'waiting' | 'uploading' | 'processing' | 'done' | 'duplicate' | 'quarantine' | 'error';
export type UploadFailure = 'unsupported' | 'too_large' | 'quota' | 'other';

export interface UploadItem {
	id: string;
	name: string;
	size: number;
	state: UploadState;
	/** 0…1 while uploading. */
	progress: number;
	failure?: UploadFailure;
	/** The error text source for `other` failures. */
	error?: unknown;
	document?: DmsDocument;
	/** Last processing status (GET …/processing); `error_code` names the quarantine reason. */
	processing?: DmsProcessing;
	duplicates: string[];
}

/** Quarantine = the ingest item failed permanently (phase `failed`); the original is kept. */
export function isQuarantined(processing: Pick<DmsProcessing, 'phase'> | null | undefined): boolean {
	return processing?.phase === 'failed';
}

/** Processing is over: finished, never started (`none`) or quarantined. Everything else is polled. */
export function isProcessingOver(processing: Pick<DmsProcessing, 'phase'>): boolean {
	return processing.phase === 'done' || processing.phase === 'none' || processing.phase === 'failed';
}

export function classifyUploadError(error: unknown): UploadFailure {
	if (error instanceof ApiError) {
		// The two 413 variants differ by code: the tenant quota is not "file too large".
		if (error.code === 'storage_quota_exceeded') return 'quota';
		if (error.status === 415 || error.code === 'unsupported_media_type') return 'unsupported';
		if (error.status === 413 || error.code === 'payload_too_large') return 'too_large';
	}
	return 'other';
}

/** 409 upload_interrupted: a concurrent upload of the same bytes was cleaned up; retry with the same key. */
export const isInterrupted = (error: unknown): boolean => error instanceof ApiError && error.code === 'upload_interrupted';

export interface UploadDeps {
	upload: (file: File, o: { idempotencyKey: string; onProgress: (f: number) => void; signal: AbortSignal }) => Promise<DmsDocument>;
	fetchProcessing: (documentId: string) => Promise<DmsProcessing>;
	retryProcessing?: (documentId: string) => Promise<DmsProcessing>;
	/** Called when a document was stored or finished processing, so the list can refresh. */
	onSettled?: (doc: DmsDocument) => void;
	pollMs?: number;
	maxPolls?: number;
	/** Pause before an automatic retry after `upload_interrupted` (same idempotency key). */
	interruptedRetryMs?: number;
	maxInterruptedRetries?: number;
	concurrency?: number;
}

/**
 * Upload queue: one request per file (the contract takes a raw body), a few in parallel, progress per file, and for
 * documents with an ingest item a poll of `GET …/processing` until processing is over (done or quarantine). A retry (manual, or automatic
 * after `upload_interrupted`) reuses the idempotency key, so a request that reached the server twice creates one document.
 */
export class UploadQueue {
	items = $state<UploadItem[]>([]);
	private readonly controller = new AbortController();
	private readonly files = new Map<string, File>();
	private readonly keys = new Map<string, string>();
	private running = 0;

	constructor(private readonly deps: UploadDeps) {}

	get busy(): boolean {
		return this.items.some((i) => i.state === 'waiting' || i.state === 'uploading' || i.state === 'processing');
	}

	add(files: Iterable<File>): void {
		for (const file of files) {
			const id = crypto.randomUUID();
			this.files.set(id, file);
			this.keys.set(id, crypto.randomUUID());
			this.items.push({ id, name: file.name, size: file.size, state: 'waiting', progress: 0, duplicates: [] });
		}
		this.pump();
	}

	retry(id: string): void {
		const item = this.item(id);
		if (!item || item.state !== 'error') return;
		item.state = 'waiting';
		item.progress = 0;
		item.failure = undefined;
		item.error = undefined;
		this.pump();
	}

	remove(id: string): void {
		this.items = this.items.filter((i) => i.id !== id || i.state === 'uploading');
		this.files.delete(id);
		this.keys.delete(id);
	}

	/** Removes finished entries and keeps problems (duplicate, quarantine, errors) visible. */
	clearFinished(): void {
		this.items = this.items.filter((i) => i.state !== 'done');
	}

	destroy(): void {
		this.controller.abort();
	}

	private pump(): void {
		const limit = this.deps.concurrency ?? 2;
		while (this.running < limit) {
			const next = this.items.find((i) => i.state === 'waiting');
			if (!next) return;
			next.state = 'uploading';
			this.running++;
			void this.run(next.id).finally(() => {
				this.running--;
				this.pump();
			});
		}
	}

	private item(id: string): UploadItem | undefined {
		return this.items.find((i) => i.id === id);
	}

	/** Quarantine action: re-queues the OCR job (`POST …/processing/retry`) and resumes polling. */
	async retryQuarantine(id: string): Promise<void> {
		const item = this.item(id);
		const documentId = item?.document?.id;
		if (!item || !documentId || item.state !== 'quarantine' || !this.deps.retryProcessing) return;
		try {
			const processing = await this.deps.retryProcessing(documentId);
			item.processing = processing;
			item.state = 'processing';
			await this.waitForProcessing(id, documentId);
		} catch (error) {
			item.state = 'error';
			item.failure = classifyUploadError(error);
			item.error = error;
		}
	}

	private async uploadWithRetry(file: File, key: string, id: string): Promise<DmsDocument> {
		const max = this.deps.maxInterruptedRetries ?? 3;
		for (let attempt = 0; ; attempt++) {
			try {
				return await this.deps.upload(file, {
					idempotencyKey: key,
					signal: this.controller.signal,
					onProgress: (fraction) => {
						const item = this.item(id);
						if (item) item.progress = fraction;
					}
				});
			} catch (error) {
				if (!isInterrupted(error) || attempt >= max || this.controller.signal.aborted) throw error;
				await new Promise((resolve) => setTimeout(resolve, this.deps.interruptedRetryMs ?? 500));
			}
		}
	}

	private async run(id: string): Promise<void> {
		const file = this.files.get(id);
		const key = this.keys.get(id);
		if (!file || !key) return;
		try {
			const doc = await this.uploadWithRetry(file, key, id);
			const item = this.item(id);
			if (!item) return;
			item.document = doc;
			item.duplicates = doc.duplicates ?? [];
			item.progress = 1;
			this.deps.onSettled?.(doc);
			if (doc.ingest_item_id) {
				item.state = 'processing';
				await this.waitForProcessing(id, doc.id);
			} else {
				item.state = item.duplicates.length > 0 ? 'duplicate' : 'done';
			}
		} catch (error) {
			const item = this.item(id);
			if (!item || this.controller.signal.aborted) return;
			item.state = 'error';
			item.failure = classifyUploadError(error);
			item.error = error;
		}
	}

	private async waitForProcessing(id: string, documentId: string): Promise<void> {
		const interval = this.deps.pollMs ?? 1000;
		const max = this.deps.maxPolls ?? 300;
		for (let i = 0; i < max; i++) {
			// First half-minute at the base interval, then slower (OCR of long scans takes minutes).
			await new Promise((resolve) => setTimeout(resolve, i < 30 ? interval : interval * 3));
			if (this.controller.signal.aborted) return;
			let processing: DmsProcessing;
			try {
				processing = await this.deps.fetchProcessing(documentId);
			} catch {
				continue;
			}
			const item = this.item(id);
			if (!item) return;
			item.processing = processing;
			if (!isProcessingOver(processing)) continue;
			item.state = isQuarantined(processing) ? 'quarantine' : item.duplicates.length > 0 ? 'duplicate' : 'done';
			if (item.document) this.deps.onSettled?.(item.document);
			return;
		}
	}
}
