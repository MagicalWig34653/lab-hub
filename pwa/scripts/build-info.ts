import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

export interface BuildInfo {
	version: string;
	revision: string;
	buildDate: string;
}

function gitRevision(): string {
	try {
		return execFileSync('git', ['rev-parse', '--short', 'HEAD'], { stdio: ['ignore', 'pipe', 'ignore'] })
			.toString()
			.trim();
	} catch {
		return 'unknown';
	}
}

export function resolveBuildInfo(): BuildInfo {
	const pkg = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')) as { version: string };
	return {
		version: pkg.version,
		revision: process.env.BUILD_REVISION ?? gitRevision(),
		buildDate: new Date().toISOString()
	};
}
