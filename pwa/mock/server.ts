// Static server for the built PWA plus the mock API. Mirrors what the backend does: files under `/`, API under `/api`,
// unknown paths fall back to index.html (deep links). Used by the mock E2E run: `node mock/server.ts` (Node >= 22.18).
import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { createMockApi } from './api.ts';

const root = join(import.meta.dirname, '..', 'build');
const port = Number(process.env.MOCK_PORT ?? 4173);
const api = createMockApi();

const types: Record<string, string> = {
	'.html': 'text/html; charset=utf-8',
	'.js': 'text/javascript; charset=utf-8',
	'.css': 'text/css; charset=utf-8',
	'.json': 'application/json',
	'.svg': 'image/svg+xml',
	'.png': 'image/png',
	'.webmanifest': 'application/manifest+json',
	'.woff2': 'font/woff2'
};

async function fileOrNull(path: string) {
	try {
		return (await stat(path)).isFile() ? path : null;
	} catch {
		return null;
	}
}

createServer(async (req, res) => {
	if (await api.handle(req, res)) return;
	const urlPath = decodeURIComponent((req.url ?? '/').split('?')[0]);
	const safe = normalize(urlPath).replace(/^(\.\.[/\\])+/, '');
	const file = (await fileOrNull(join(root, safe))) ?? (await fileOrNull(join(root, safe, 'index.html')));
	// Unknown paths with a file extension are real 404s; everything else is an SPA route.
	const target = file ?? (extname(safe) ? null : join(root, 'index.html'));
	if (!target) {
		res.writeHead(404).end();
		return;
	}
	res.writeHead(200, { 'content-type': types[extname(target)] ?? 'application/octet-stream' });
	res.end(await readFile(target));
}).listen(port, 'localhost', () => {
	console.log(`mock server on http://localhost:${port}`);
});
