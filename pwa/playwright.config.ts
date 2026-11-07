import { defineConfig, devices } from '@playwright/test';

// E2E against a real backend (fresh database, SETUP_TOKEN set, PUBLIC_URL=http://localhost:<E2E_PORT>,
// WEBAUTHN_RP_ID=localhost). The PWA runs on the Vite dev server, which proxies /api to E2E_BACKEND_URL,
// so browser and API share one origin (cookie session, RP ID = host).
const port = Number(process.env.E2E_PORT ?? 5173);
const backend = process.env.E2E_BACKEND_URL ?? 'http://127.0.0.1:8080';

export default defineConfig({
	testDir: 'e2e',
	fullyParallel: false,
	workers: 1,
	retries: 0,
	timeout: 20_000,
	reporter: 'list',
	use: { baseURL: `http://localhost:${port}`, locale: 'de-DE', trace: 'retain-on-failure' },
	projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
	webServer: {
		command: `npx vite dev --host localhost --port ${port} --strictPort`,
		env: { BACKEND_URL: backend },
		url: `http://localhost:${port}/login`,
		reuseExistingServer: false,
		timeout: 60_000
	}
});
