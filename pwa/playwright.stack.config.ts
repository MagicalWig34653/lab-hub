import { defineConfig, devices } from '@playwright/test';

// WP-H9: E2E against the deployed stack (compose: db, backend image with the PWA, worker image). No dev server:
// the browser talks to the backend container directly at http://localhost:<E2E_PORT>, which serves PWA and API from one origin.
// The stack needs SETUP_TOKEN (= E2E_SETUP_TOKEN), PUBLIC_URL=http://localhost:<E2E_PORT>, WEBAUTHN_RP_ID=localhost and a fresh database.
const port = Number(process.env.E2E_PORT ?? 8080);

export default defineConfig({
	testDir: 'e2e',
	testMatch: ['dms.spec.ts', 'stack-restart.spec.ts'],
	fullyParallel: false,
	workers: 1,
	retries: 0,
	timeout: 20_000,
	reporter: 'list',
	use: { baseURL: `http://localhost:${port}`, locale: 'de-DE', trace: 'retain-on-failure' },
	projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }]
});
