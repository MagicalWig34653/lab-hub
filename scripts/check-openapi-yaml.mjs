// WP-H7: contracts/openapi.yaml muss gültiges YAML sein (der Swift-Vertragstest nutzt nur einen Zeilenparser).
// Nutzt js-yaml aus pwa/node_modules (Abhängigkeit von openapi-typescript), keine neue Abhängigkeit. Doppelte Schlüssel gelten als Fehler.
import { createRequire } from 'node:module';
import { existsSync, readFileSync } from 'node:fs';

const root = new URL('..', import.meta.url);
if (!existsSync(new URL('pwa/node_modules/js-yaml', root))) {
	console.error('pwa/node_modules fehlt: erst `npm --prefix pwa ci` ausführen (YAML-Prüfung braucht js-yaml daraus).');
	process.exit(2);
}
const yaml = createRequire(new URL('pwa/package.json', root))('js-yaml');
const file = new URL('contracts/openapi.yaml', root);
try {
	const doc = yaml.load(readFileSync(file, 'utf8'));
	if (!doc || typeof doc !== 'object' || !doc.openapi || !doc.paths) throw new Error('kein OpenAPI-Dokument (openapi/paths fehlen)');
	console.log(`contracts/openapi.yaml: gültiges YAML (${Object.keys(doc.paths).length} Pfade)`);
} catch (e) {
	console.error(`contracts/openapi.yaml: ungültiges YAML: ${e.message}`);
	process.exit(1);
}
