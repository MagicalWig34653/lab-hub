import { defineConfig, devices } from '@playwright/test';

// E2E against the built bundle + mock backend (mock/server.ts). `npm run test:e2e:mock` builds first.
const port = Number(process.env.E2E_MOCK_PORT ?? 4173);

export default defineConfig({
	testDir: 'e2e-mock',
	fullyParallel: false,
	workers: 1,
	retries: 0,
	timeout: 20_000,
	reporter: 'list',
	use: { baseURL: `http://localhost:${port}`, locale: 'de-DE', trace: 'retain-on-failure' },
	projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
	webServer: {
		// `localhost` (not an IP) is a valid WebAuthn RP ID and a secure context.
		command: 'node mock/server.ts',
		env: { MOCK_PORT: String(port) },
		url: `http://localhost:${port}/api/version`,
		reuseExistingServer: false,
		timeout: 30_000
	}
});
