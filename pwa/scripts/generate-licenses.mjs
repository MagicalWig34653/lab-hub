// Writes static/licenses.json (name, version, license of all locked packages) for the build (FRONTEND.md section 2).
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';

const lock = JSON.parse(readFileSync(new URL('../package-lock.json', import.meta.url), 'utf8'));
const entries = [];
for (const [path, info] of Object.entries(lock.packages ?? {})) {
	if (!path.startsWith('node_modules/')) continue;
	const name = path.replace(/^.*node_modules\//, '');
	entries.push({ name, version: info.version, license: info.license ?? 'unknown' });
}
entries.sort((a, b) => a.name.localeCompare(b.name));
const target = new URL('../static/', import.meta.url);
mkdirSync(target, { recursive: true });
writeFileSync(
	new URL('licenses.json', target),
	JSON.stringify({ project: 'AGPL-3.0-only', packages: entries }, null, 1) + '\n'
);
console.log(`licenses.json: ${entries.length} packages`);
