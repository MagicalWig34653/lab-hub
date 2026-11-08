import CopyIcon from '@lucide/svelte/icons/copy';
import FileText from '@lucide/svelte/icons/file-text';
import InboxIcon from '@lucide/svelte/icons/inbox';
import KeyRound from '@lucide/svelte/icons/key-round';
import ListChecks from '@lucide/svelte/icons/list-checks';
import MailIcon from '@lucide/svelte/icons/mail';
import PackageOpen from '@lucide/svelte/icons/package-open';
import ScanLine from '@lucide/svelte/icons/scan-line';
import ScrollText from '@lucide/svelte/icons/scroll-text';
import ShieldCheck from '@lucide/svelte/icons/shield-check';
import TagsIcon from '@lucide/svelte/icons/tags';
import TrashIcon from '@lucide/svelte/icons/trash';
import type { NavGroupDef } from '#lib/modules/manifest';
import { P } from './permissions';

/**
 * Sidebar sections of the DMS (WP-F4c): "Dokumente" for daily work, "Verwaltung" for rules, master data, sources and checks.
 * Items appear only with their permission (visibility; the backend authorizes). Test ids keep the former tab names
 * (`dms-nav-<segment>`), the overview carries `nav-dms`.
 */
export const dmsNavigation: NavGroupDef[] = [
	{
		id: 'documents',
		labelKey: 'dms.nav.group.documents',
		items: [
			// The overview is also current on a document detail page (/dms/<uuid>).
			{ id: 'overview', path: '/dms', labelKey: 'dms.nav.overview', icon: FileText, permission: 'dms.document.read', testId: 'nav-dms', matches: /^\/dms(\/[0-9a-f-]{36})?$/ },
			{ id: 'inbox', path: '/dms/inbox', labelKey: 'dms.nav.inbox', icon: InboxIcon, permission: 'dms.document.read', testId: 'dms-nav-inbox' },
			{ id: 'review', path: '/dms/review', labelKey: 'dms.nav.review', icon: ListChecks, permission: P.suggestionRead, testId: 'dms-nav-review' },
			{ id: 'duplicates', path: '/dms/duplicates', labelKey: 'dms.nav.duplicates', icon: CopyIcon, permission: 'dms.document.read', testId: 'dms-nav-duplicates' },
			{ id: 'trash', path: '/dms/trash', labelKey: 'dms.nav.trash', icon: TrashIcon, permission: P.documentTrash, testId: 'dms-nav-trash' }
		]
	},
	{
		id: 'admin',
		labelKey: 'dms.nav.group.admin',
		items: [
			{ id: 'rules', path: '/dms/rules', labelKey: 'dms.nav.rules', icon: ScrollText, permission: P.ruleRead, testId: 'dms-nav-rules' },
			{ id: 'masters', path: '/dms/masters', labelKey: 'dms.nav.masters', icon: TagsIcon, permission: 'dms.document.read', testId: 'dms-nav-masters' },
			{ id: 'sources', path: '/dms/sources', labelKey: 'dms.nav.sources', icon: MailIcon, permission: P.sourceRead, testId: 'dms-nav-sources' },
			{ id: 'tokens', path: '/dms/tokens', labelKey: 'dms.nav.tokens', icon: KeyRound, permission: P.documentCreate, testId: 'dms-nav-tokens' },
			{ id: 'scanner', path: '/dms/scanner', labelKey: 'dms.nav.scanner', icon: ScanLine, permission: P.documentCreate, testId: 'dms-nav-scanner' },
			{ id: 'integrity', path: '/dms/integrity', labelKey: 'dms.nav.integrity', icon: ShieldCheck, permission: P.integrityRun, testId: 'dms-nav-integrity' },
			{ id: 'exports', path: '/dms/exports', labelKey: 'dms.nav.exports', icon: PackageOpen, permission: P.exportRun, testId: 'dms-nav-exports' }
		]
	}
];
