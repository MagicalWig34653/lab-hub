// Fails when src/lib/api/types.ts is not what openapi-typescript generates from contracts/openapi.yaml (F-17).
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const dir = mkdtempSync(join(tmpdir(), 'lh-api-'));
const out = join(dir, 'types.ts');
try {
	execFileSync('npx', ['openapi-typescript', '../contracts/openapi.yaml', '-o', out], { stdio: 'ignore' });
	const fresh = readFileSync(out, 'utf8');
	const committed = readFileSync(new URL('../src/lib/api/types.ts', import.meta.url), 'utf8');
	if (fresh !== committed) {
		console.error('src/lib/api/types.ts is stale: run `npm run gen:api` and commit the result.');
		process.exit(1);
	}
	console.log('api types are up to date');
} finally {
	rmSync(dir, { recursive: true, force: true });
}
