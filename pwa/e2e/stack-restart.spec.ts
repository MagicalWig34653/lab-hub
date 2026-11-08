import { expect, test } from '@playwright/test';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { addVirtualAuthenticator } from './virtual-authenticator';

// WP-H9: stateless check against the deployed stack. A session created before a backend container restart stays valid
// afterwards (the session lives in the database, not in the instance). Needs a fresh stack database, SETUP_TOKEN and the
// container names to restart (STACK_RESTART_CONTAINERS, comma separated). Run: `npm run test:e2e:stack-restart`.
const execFileAsync = promisify(execFile);
const setupToken = process.env.E2E_SETUP_TOKEN;
const containers = (process.env.STACK_RESTART_CONTAINERS ?? '').split(',').filter(Boolean);

test.skip(!setupToken || containers.length === 0, 'E2E_SETUP_TOKEN/STACK_RESTART_CONTAINERS not set');

test('H9: session survives a restart of the backend containers', async ({ browser, baseURL }) => {
	test.setTimeout(180_000);
	const context = await browser.newContext();
	const page = await context.newPage();
	await addVirtualAuthenticator(context, page);
	await page.goto('/setup');
	await page.getByLabel('Setup-Token').fill(setupToken!);
	await page.getByLabel('Kennung').fill('owner');
	await page.getByLabel('Anzeigename').fill('Owner Test');
	await page.getByRole('button', { name: 'Passkey anlegen und starten' }).click();
	await expect(page).toHaveURL(/\/dashboard$/);

	await execFileAsync('docker', ['restart', ...containers]);
	await expect
		.poll(async () => (await fetch(`${baseURL}/ready`).catch(() => ({ status: 0 }))).status, { timeout: 90_000, intervals: [1000] })
		.toBe(200);

	// Same cookie, new process: still signed in, no login page.
	await page.goto('/dashboard');
	await expect(page).toHaveURL(/\/dashboard$/);
	await page.goto('/settings/modules');
	await expect(page.getByTestId('module-toggle-dms')).toBeVisible();
});
