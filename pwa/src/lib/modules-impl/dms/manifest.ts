import FileText from '@lucide/svelte/icons/file-text';
import type { ModuleManifest } from '#lib/modules/manifest';

/** DMS hook-in point. WP-F4 adds the real pages below `src/routes/(app)/dms/`; until then there is only a placeholder. */
export const dmsManifest: ModuleManifest = {
	key: 'dms',
	routePrefix: '/dms',
	icon: FileText,
	messages: {
		de: {
			'nav.dms': 'Dokumente',
			'dms.placeholder.title': 'Dokumente',
			'dms.placeholder.text': 'Die Dokumentenverwaltung wird hier eingehängt. Die Oberfläche folgt in einem späteren Arbeitspaket.'
		},
		en: {
			'nav.dms': 'Documents',
			'dms.placeholder.title': 'Documents',
			'dms.placeholder.text': 'Document management will be mounted here. The interface follows in a later work package.'
		}
	}
};
