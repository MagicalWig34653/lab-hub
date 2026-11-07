import tailwindcss from '@tailwindcss/vite';
import adapter from '@sveltejs/adapter-static';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vitest/config';
import { mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import type { Adapter } from '@sveltejs/kit';
import { mockApiPlugin } from './mock/vite-plugin.ts';
import { resolveBuildInfo } from './scripts/build-info.ts';

// `VITE_MOCK=1 vite dev` serves the in-repo mock API instead of proxying to the backend.
const useMock = process.env.VITE_MOCK === '1';
const backendUrl = process.env.BACKEND_URL ?? 'http://127.0.0.1:8080';

// build/version.json is read by the backend (and by operators) to tell which PWA build is deployed.
const buildInfo = resolveBuildInfo();
const staticAdapter = adapter({ pages: 'build', assets: 'build', fallback: 'index.html' });
const adapterWithVersion: Adapter = {
	...staticAdapter,
	async adapt(builder) {
		await staticAdapter.adapt(builder);
		mkdirSync('build', { recursive: true });
		writeFileSync('build/version.json', JSON.stringify(buildInfo, null, 2) + '\n');
	}
};

export default defineConfig({
	define: {
		__APP_VERSION__: JSON.stringify(buildInfo.version),
		__APP_REVISION__: JSON.stringify(buildInfo.revision),
		__APP_BUILD_DATE__: JSON.stringify(buildInfo.buildDate)
	},
	plugins: [
		tailwindcss(),
		sveltekit({
			compilerOptions: {
				// Force runes mode for the project, except for libraries.
				runes: ({ filename }) => (filename.split(/[/\\]/).includes('node_modules') ? undefined : true)
			},
			// SPA fallback: the backend serves build/index.html for unknown paths so deep links work.
			adapter: adapterWithVersion,
			// The service worker arrives with WP-F3.
			serviceWorker: { register: false }
		}),
		...(useMock ? [mockApiPlugin()] : [])
	],
	server: {
		// Single origin in development so the HttpOnly session cookie works (RP-ID `localhost`).
		proxy: useMock ? undefined : { '/api': { target: backendUrl, changeOrigin: false } }
	},
	resolve: {
		// `#lib` as extensionless alias (package.json `imports` stays for the shadcn CLI; tsconfig `paths` mirrors this).
		alias: [{ find: /^#lib(\/|$)/, replacement: fileURLToPath(new URL('./src/lib/', import.meta.url)) }],
		conditions: process.env.VITEST ? ['browser'] : undefined
	},
	test: {
		environment: 'jsdom',
		testTimeout: 30_000,
		hookTimeout: 30_000,
		include: ['src/**/*.test.ts', 'mock/**/*.test.ts'],
		setupFiles: ['./vitest-setup.ts']
	}
});
