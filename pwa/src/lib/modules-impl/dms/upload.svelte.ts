import { ApiError, type DmsDocument } from '#lib/api/client';

export type UploadState = 'waiting' | 'uploading' | 'processing' | 'done' | 'duplicate' | 'quarantine' | 'error';
export type UploadFailure = 'unsupported' | 'too_large' | 'other';

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
	duplicates: string[];
}

/**
 * Optional ingest fields. NOT part of the contract yet (WP-O2/D3 will deliver the ingest state); the mock sends them.
 * The UI uses them when present and otherwise relies on `status` only.
 */
export type WithIngest = DmsDocument & { ingest_state?: string; ingest_error_code?: string };

export function isQuarantined(doc: DmsDocument): boolean {
	return (doc as WithIngest).ingest_state === 'failed_permanent';
}

export function classifyUploadError(error: unknown): UploadFailure {
	if (error instanceof ApiError) {
		if (error.status === 415 || error.code === 'unsupported_media_type') return 'unsupported';
		if (error.status === 413 || error.code === 'payload_too_large') return 'too_large';
	}
	return 'other';
}

export interface UploadDeps {
	upload: (file: File, o: { idempotencyKey: string; onProgress: (f: number) => void; signal: AbortSignal }) => Promise<DmsDocument>;
	fetchDocument: (id: string) => Promise<DmsDocument>;
	/** Called when a document was stored or finished processing, so the list can refresh. */
	onSettled?: (doc: DmsDocument) => void;
	pollMs?: number;
	maxPolls?: number;
	concurrency?: number;
}

/**
 * Upload queue: one request per file (the contract takes a raw body), a few in parallel, progress per file, and for
 * documents that are still `processing` a poll until the document leaves that state. A retry reuses the idempotency
 * key, so a request that reached the server twice creates one document.
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

	private async run(id: string): Promise<void> {
		const file = this.files.get(id);
		const key = this.keys.get(id);
		if (!file || !key) return;
		try {
			const doc = await this.deps.upload(file, {
				idempotencyKey: key,
				signal: this.controller.signal,
				onProgress: (fraction) => {
					const item = this.item(id);
					if (item) item.progress = fraction;
				}
			});
			const item = this.item(id);
			if (!item) return;
			item.document = doc;
			item.duplicates = doc.duplicates ?? [];
			item.progress = 1;
			if (isQuarantined(doc)) {
				item.state = 'quarantine';
				this.deps.onSettled?.(doc);
			} else if (doc.status === 'processing') {
				item.state = 'processing';
				this.deps.onSettled?.(doc);
				await this.waitForProcessing(id, doc.id);
			} else {
				item.state = item.duplicates.length > 0 ? 'duplicate' : 'done';
				this.deps.onSettled?.(doc);
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
		for (let i = 0; i < (this.deps.maxPolls ?? 120); i++) {
			await new Promise((resolve) => setTimeout(resolve, interval));
			if (this.controller.signal.aborted) return;
			let doc: DmsDocument;
			try {
				doc = await this.deps.fetchDocument(documentId);
			} catch {
				continue;
			}
			const item = this.item(id);
			if (!item) return;
			if (doc.status === 'processing' && !isQuarantined(doc)) continue;
			item.document = doc;
			item.state = isQuarantined(doc) ? 'quarantine' : item.duplicates.length > 0 ? 'duplicate' : 'done';
			this.deps.onSettled?.(doc);
			return;
		}
	}
}
