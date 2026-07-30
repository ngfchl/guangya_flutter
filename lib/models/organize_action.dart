enum OrganizeActionType {
  moveToBase,
  renameBase,
  renameConflict,
  deleteDuplicate,
  cleanDir,
}

class OrganizeAction {
  final OrganizeActionType type;
  final String sourceId;
  final String sourceName;
  final bool sourceIsDir;
  final String sourceParentId;
  final String sourcePath;
  final String? newFileName;
  final String? targetParentId;
  final String? targetParentName;
  final String? targetPath;
  final String reason;

  bool executed;
  bool failed;
  String? errorMessage;

  OrganizeAction({
    required this.type,
    required this.sourceId,
    required this.sourceName,
    required this.sourceIsDir,
    required this.sourceParentId,
    required this.sourcePath,
    this.newFileName,
    this.targetParentId,
    this.targetParentName,
    this.targetPath,
    required this.reason,
    this.executed = false,
    this.failed = false,
    this.errorMessage,
  });
}
