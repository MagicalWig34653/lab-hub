import type { Plugin } from 'vite';
import { createMockApi } from './api.ts';

/** Serves the mock API from the Vite dev server (`npm run dev:mock`). */
export function mockApiPlugin(): Plugin {
	const api = createMockApi();
	return {
		name: 'lab-hub-mock-api',
		configureServer(server) {
			server.middlewares.use((req, res, next) => {
				api.handle(req, res).then(
					(handled) => {
						if (!handled) next();
					},
					next
				);
			});
		}
	};
}
