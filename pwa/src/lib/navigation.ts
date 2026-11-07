/** Only same-origin absolute paths are valid post-login targets (no open redirect via `//host` or `https:`). */
export function safeNext(next: string | null | undefined, fallback = '/dashboard'): string {
	if (!next || !next.startsWith('/') || next.startsWith('//') || next.startsWith('/\\')) return fallback;
	return next;
}
