// Applies the stored colour scheme and accent before the app starts (no flash of the wrong colours, WP-ST4/ST7).
// External file so that the strict CSP (script-src 'self') allows it. Keys: see src/lib/theme/theme.svelte.ts.
(function () {
	var root = document.documentElement;
	var mode = null;
	var accent = null;
	try {
		mode = localStorage.getItem('lh.theme');
		accent = localStorage.getItem('lh.accent');
	} catch (e) {
		// storage blocked: follow the system
	}
	var dark = mode === 'dark' || (mode !== 'light' && window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);
	root.classList.toggle('dark', !!dark);
	if (accent && /^#[0-9a-f]{6}$/.test(accent)) root.style.setProperty('--ui-accent', accent);
})();
