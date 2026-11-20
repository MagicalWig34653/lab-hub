#!/usr/bin/env node
// WP-H1: erzeugt die SBOM (CycloneDX 1.5, JSON) mit SPDX-Lizenzangaben für alle aufgelösten Abhängigkeiten
// (SwiftPM: backend/Package.resolved + Checkouts, npm: pwa/package-lock.json) und prüft sie.
// Reproduzierbar: keine Zeitstempel, keine Zufalls-IDs, sortierte Ausgabe, keine Netzwerkzugriffe, keine externen Dienste.
//
//   node scripts/generate-sbom.mjs [--check] [--checkouts <dir>] [--out <file>]
//
// Standard: schreibt legal/sbom/lab-hub.cdx.json. --check schreibt nichts, vergleicht mit der eingecheckten Datei
// und scheitert bei fehlenden/nicht zuordenbaren Lizenzen, ungültigen SPDX-Ausdrücken oder abweichenden Revisionen.
// Checkouts: $LH_SCRATCH/checkouts (Standard $TMPDIR/labhub-build/checkouts), entstehen durch `swift package resolve|build`.
// Handgepflegte Ausnahmen mit Begründung: legal/sbom/license-overrides.json. Keine Rechtsberatung, keine Freigabe.
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const flag = (n) => args.includes(n);
const opt = (n, d) => (args.includes(n) ? args[args.indexOf(n) + 1] : d);
const check = flag('--check');
const outFile = resolve(opt('--out', join(root, 'legal/sbom/lab-hub.cdx.json')));
const scratch = process.env.LH_SCRATCH ?? join(process.env.TMPDIR ?? '/tmp', 'labhub-build');
const checkouts = resolve(opt('--checkouts', join(scratch, 'checkouts')));
const overridesFile = join(root, 'legal/sbom/license-overrides.json');

// Bekannte SPDX-Kennungen (Richtlinie: neue Kennung = bewusste Aufnahme hier, danach Prüfung durch den Nutzer).
const KNOWN = new Set([
	'Apache-2.0', 'MIT', 'MIT-0', 'ISC', 'BSD-2-Clause', 'BSD-3-Clause', '0BSD', 'CC0-1.0', 'BlueOak-1.0.0',
	'OFL-1.1', 'MPL-2.0', 'Python-2.0', 'Unlicense', 'AGPL-3.0-only'
]);
const problems = [];
const problem = (m) => problems.push(m);

const overrides = existsSync(overridesFile) ? JSON.parse(readFileSync(overridesFile, 'utf8')).overrides ?? {} : {};
const usedOverrides = new Set();

function validExpression(expr) {
	const ids = expr.replace(/[()]/g, ' ').split(/\s+(?:OR|AND|WITH)\s+|\s+/).filter(Boolean).filter((t) => !['OR', 'AND', 'WITH'].includes(t));
	return ids.length > 0 && ids.every((id) => KNOWN.has(id));
}

function classify(text) {
	const t = text.replace(/\s+/g, ' ');
	if (/Apache License,? Version 2\.0/i.test(t) && /TERMS AND CONDITIONS FOR USE, REPRODUCTION/i.test(t)) return 'Apache-2.0';
	if (/Permission is hereby granted, free of charge/i.test(t)) return 'MIT';
	if (/free and unencumbered software released into the public domain/i.test(t)) return 'Unlicense';
	if (/Redistribution and use in source and binary forms/i.test(t)) return /Neither the name of/i.test(t) ? 'BSD-3-Clause' : 'BSD-2-Clause';
	if (/Permission to use, copy, modify, and\/or distribute this software for any purpose with or without fee/i.test(t)) return 'ISC';
	return null;
}

function applyOverride(key, detected) {
	const o = overrides[key];
	if (!o) return detected;
	usedOverrides.add(key);
	if (!o.license || !o.reason) problem(`Ausnahme ${key} ohne license/reason`);
	return o.license;
}

const components = [];

// --- SwiftPM -------------------------------------------------------------------------------------------------------
const resolved = JSON.parse(readFileSync(join(root, 'backend/Package.resolved'), 'utf8'));
for (const pin of resolved.pins) {
	const id = pin.identity;
	const loc = pin.location.replace(/^https?:\/\//, '').replace(/\.git$/, '');
	const rev = pin.state.revision;
	const version = pin.state.version ?? rev;
	const dir = join(checkouts, id);
	let license = null;
	if (!existsSync(dir)) {
		problem(`swiftpm:${id}: kein Checkout unter ${dir} (zuerst \`swift package resolve\`/Build)`);
	} else {
		const head = execFileSync('git', ['-C', dir, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();
		if (head !== rev) problem(`swiftpm:${id}: Checkout ${head} != Package.resolved ${rev}`);
		const f = readdirSync(dir).find((n) => /^(license|licence|copying|unlicense)(\.(txt|md))?$/i.test(n));
		if (f) license = classify(readFileSync(join(dir, f), 'utf8'));
	}
	license = applyOverride(`swiftpm:${id}`, license);
	components.push({
		eco: 'swiftpm', key: `swiftpm:${id}`, name: loc, version, license,
		purl: `pkg:swift/${loc}@${version}`,
		extra: { revision: rev, url: pin.location }
	});
}

// --- npm -----------------------------------------------------------------------------------------------------------
const lock = JSON.parse(readFileSync(join(root, 'pwa/package-lock.json'), 'utf8'));
for (const [path, info] of Object.entries(lock.packages ?? {})) {
	if (!path.startsWith('node_modules/')) continue;
	const name = path.replace(/^.*node_modules\//, '');
	const key = `npm:${name}`;
	let license = typeof info.license === 'string' ? info.license : null;
	license = applyOverride(key, license);
	const hash = /^sha512-(.+)$/.exec(info.integrity ?? '');
	components.push({
		eco: 'npm', key, name, version: info.version, license,
		purl: `pkg:npm/${name.replace('@', '%40')}@${info.version}`,
		hash: hash ? Buffer.from(hash[1], 'base64').toString('hex') : null,
		extra: { dev: info.dev ? 'true' : 'false', optional: info.optional ? 'true' : 'false' }
	});
}

// --- vendored: BoringSSL in swift-nio-ssl (siehe legal/THIRD-PARTY-NOTICES.md) ---------------------------------------
const nioSsl = components.find((c) => c.key === 'swiftpm:swift-nio-ssl');
const bssl = readFileSync(join(root, 'legal/THIRD-PARTY-NOTICES.md'), 'utf8').match(/revision `([0-9a-f]{40})`/g) ?? [];
const bsslRev = '8eb25be6fa18d475291122887a7bccd3762ff236';
if (!bssl.some((m) => m.includes(bsslRev))) problem('BoringSSL-Revision in legal/THIRD-PARTY-NOTICES.md nicht gefunden');
if (nioSsl) {
	components.push({
		eco: 'generic', key: 'vendored:boringssl', name: 'boringssl (gebündelt in swift-nio-ssl)', version: bsslRev, license: 'Apache-2.0',
		purl: `pkg:generic/boringssl@${bsslRev}`, extra: { 'bundled-in': `swift-nio-ssl@${nioSsl.version}` }
	});
}

// --- Prüfung -------------------------------------------------------------------------------------------------------
for (const c of components) {
	if (!c.license) problem(`${c.key}@${c.version}: Lizenz fehlt/nicht zuordenbar (Ausnahme mit Begründung in legal/sbom/license-overrides.json)`);
	else if (!validExpression(c.license)) problem(`${c.key}@${c.version}: "${c.license}" ist kein bekannter SPDX-Ausdruck (KNOWN in scripts/generate-sbom.mjs)`);
}
for (const k of Object.keys(overrides)) if (!usedOverrides.has(k)) problem(`Ausnahme ${k} wird nicht mehr gebraucht (entfernen)`);

// --- CycloneDX 1.5, deterministisch --------------------------------------------------------------------------------
components.sort((a, b) => a.purl.localeCompare(b.purl));
const bom = {
	bomFormat: 'CycloneDX',
	specVersion: '1.5',
	version: 1,
	metadata: {
		tools: { components: [{ type: 'application', name: 'scripts/generate-sbom.mjs' }] },
		component: { type: 'application', 'bom-ref': 'lab-hub', name: 'lab-hub', licenses: [{ license: { id: 'AGPL-3.0-only' } }] },
		properties: [
			{ name: 'labhub:scope', value: 'SwiftPM (backend/Package.resolved), npm (pwa/package-lock.json), vendored BoringSSL; nicht enthalten: Betriebssystem-/Toolchain-Pakete der Images' }
		]
	},
	components: components.map((c) => {
		const lic = c.license ?? 'NOASSERTION';
		const comp = {
			type: 'library',
			'bom-ref': c.purl,
			name: c.name,
			version: c.version,
			purl: c.purl,
			licenses: /\s/.test(lic) ? [{ expression: lic }] : [{ license: { id: lic } }]
		};
		if (c.hash) comp.hashes = [{ alg: 'SHA-512', content: c.hash }];
		comp.properties = [{ name: 'labhub:ecosystem', value: c.eco }, ...Object.entries(c.extra ?? {}).map(([name, value]) => ({ name: `labhub:${name}`, value }))];
		return comp;
	})
};
const text = JSON.stringify(bom, null, 2) + '\n';

const counts = {};
for (const c of components) counts[c.license ?? 'NOASSERTION'] = (counts[c.license ?? 'NOASSERTION'] ?? 0) + 1;
console.log(`Komponenten: ${components.length} (swiftpm ${components.filter((c) => c.eco === 'swiftpm').length}, npm ${components.filter((c) => c.eco === 'npm').length}, vendored ${components.filter((c) => c.eco === 'generic').length})`);
console.log('Lizenzen: ' + Object.entries(counts).sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).map(([k, v]) => `${k} ${v}`).join(', '));

if (check) {
	if (!existsSync(outFile)) problem(`${outFile} fehlt (node scripts/generate-sbom.mjs)`);
	else if (readFileSync(outFile, 'utf8') !== text) problem(`${outFile} ist nicht aktuell (node scripts/generate-sbom.mjs ausführen und committen)`);
}
if (problems.length) {
	for (const p of problems) console.error(`FEHLER: ${p}`);
	process.exit(1);
}
if (!check) {
	mkdirSync(dirname(outFile), { recursive: true });
	writeFileSync(outFile, text);
	console.log(`geschrieben: ${outFile}`);
} else console.log('check-sbom: ok');
