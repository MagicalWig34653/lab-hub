import { ApiError, authApi, setCsrfToken, setSessionEndedHandler, type SessionResponse } from '#lib/api/client';
import { createPasskey, getPasskey } from '#lib/webauthn';

class SessionStore {
	current = $state<SessionResponse | null>(null);
	loaded = $state(false);

	get isRecovery() {
		return this.current?.kind === 'recovery';
	}

	apply(session: SessionResponse | null) {
		this.current = session;
		this.loaded = true;
		setCsrfToken(session?.csrf_token ?? null);
	}

	/** Reads the server session (cookie). 401 means signed out; everything else propagates. */
	async refresh(): Promise<SessionResponse | null> {
		try {
			this.apply(await authApi.session());
		} catch (error) {
			if (error instanceof ApiError && error.status === 401) this.apply(null);
			else throw error;
		}
		return this.current;
	}

	async login() {
		const { challenge_id, public_key } = await authApi.loginOptions();
		const credential = await getPasskey(public_key);
		this.apply(await authApi.loginVerify({ challenge_id, credential }));
	}

	async bootstrap(input: { setup_token: string; handle: string; display_name: string; tenant_name?: string }) {
		const { challenge_id, public_key } = await authApi.bootstrapOptions(input);
		const credential = await createPasskey(public_key);
		this.apply(await authApi.bootstrapVerify({ challenge_id, credential }));
	}

	async acceptInvitation(input: { invite_token: string; handle: string; display_name: string }) {
		const { challenge_id, public_key } = await authApi.registerOptions(input);
		const credential = await createPasskey(public_key);
		this.apply(await authApi.registerVerify({ challenge_id, credential }));
	}

	async recover(handle: string, code: string) {
		this.apply(await authApi.recoveryLogin({ handle, code }));
	}

	/** Adds a passkey to the current session; after a recovery login this upgrades it to a normal session. */
	async addPasskey(name: string) {
		const { challenge_id, public_key } = await authApi.addPasskeyOptions();
		const credential = await createPasskey(public_key);
		await authApi.addPasskeyVerify({ challenge_id, credential, name });
		await this.refresh();
	}

	async logout() {
		try {
			await authApi.logout();
		} finally {
			this.apply(null);
		}
	}
}

export const session = new SessionStore();

/** A 401 on a data call while signed in means the session is gone: forget it so the guard redirects. */
setSessionEndedHandler(() => session.apply(null));
