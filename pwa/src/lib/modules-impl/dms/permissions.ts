/** DMS permission names (backend `DMSModule.permissions`). They are not texts; the i18n tests skip this file. */
export const P = {
	documentTrash: 'dms.document.trash',
	documentPurge: 'dms.document.purge',
	documentRetention: 'dms.document.retention',
	documentUpdate: 'dms.document.update',
	suggestionRead: 'dms.suggestion.read',
	suggestionDecide: 'dms.suggestion.decide',
	ruleRead: 'dms.rule.read',
	ruleManage: 'dms.rule.manage',
	masterManage: 'dms.master.manage',
	tagManage: 'dms.tag.manage',
	integrityRun: 'dms.integrity.run',
	exportRun: 'dms.export.run'
} as const;
