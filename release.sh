#!/usr/bin/env bash
set -euo pipefail

export GIT_PAGER=cat
export PAGER=cat

REMOTE="github"
SOURCE_BRANCH="dev"
TARGET_BRANCH="main"
PUBSPEC_FILE="pubspec.yaml"
REQUESTED_VERSION=""
DRY_RUN=false
YES=false
RETURN_TO_SOURCE_ON_ERROR=false

usage() {
  cat <<'EOF'
用法: ./release.sh [选项]

选项:
  --version <版本>    指定版本，如 1.2.3 或 1.2.3+45
  --source <分支>     发布源分支。默认: dev
  --target <分支>     发布目标分支。默认: main
  --remote <远程>     Git 远程仓库。默认: github
  --pubspec <文件>    pubspec.yaml 路径。默认: pubspec.yaml
  --dry-run           显示发布计划，不修改文件或 Git 状态
  -y, --yes           自动确认发布流程
  -h, --help          显示帮助信息

版本规则:
  默认将补丁版本和 Flutter build number 按十进制各加 1：
    1.0.0+1 -> 1.0.1+2
  --version 不带 build number 时，沿用自动递增后的 build number：
    --version 1.2.3 -> 1.2.3+2
  --version 带 build number 时，使用完整指定值：
    --version 1.2.3+45 -> 1.2.3+45
  Git 标签不包含 build metadata，例如 1.2.3+45 对应 v1.2.3。

发布流程:
  1. 检查工作区并同步源分支和目标分支。
  2. 更新 pubspec.yaml，在源分支提交版本号。
  3. 将源分支快进合并到目标分支。
  4. 创建带说明的版本标签。
  5. 原子推送源分支、目标分支和标签，最后返回源分支。
EOF
}

die() {
  echo "错误: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

require_option_value() {
  local option="$1"
  local value="${2:-}"
  [ -n "$value" ] || die "$option 需要一个参数"
}

run() {
  "$@"
}

handle_exit() {
  local status="$?"

  if [ "$status" -ne 0 ] && [ "$RETURN_TO_SOURCE_ON_ERROR" = true ]; then
    if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
      git checkout "$SOURCE_BRANCH" >/dev/null 2>&1 || true
    fi
    echo "发布未完成；已保留本地发布状态，请检查后重试。" >&2
  fi

  return "$status"
}

local_branch_exists() {
  git show-ref --verify --quiet "refs/heads/$1"
}

remote_branch_exists() {
  git show-ref --verify --quiet "refs/remotes/$REMOTE/$1"
}

resolve_branch_ref() {
  local branch="$1"

  if local_branch_exists "$branch"; then
    printf '%s\n' "$branch"
  elif remote_branch_exists "$branch"; then
    printf '%s/%s\n' "$REMOTE" "$branch"
  else
    return 1
  fi
}

read_version() {
  local file="$1"
  awk '/^version:[[:space:]]*/ { print $2; found = 1; exit } END { if (!found) exit 2 }' "$file"
}

read_version_from_ref() {
  local ref="$1"
  local file="$2"
  git show "$ref:$file" |
    awk '/^version:[[:space:]]*/ { print $2; found = 1; exit } END { if (!found) exit 2 }'
}

decimal() {
  local value="$1"
  printf '%d\n' "$((10#$value))"
}

calculate_version() {
  local old_version="$1"
  local requested_version="$2"
  local old_major old_minor old_patch old_build
  local new_major new_minor new_patch new_build

  if [[ ! "$old_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\+([0-9]+)$ ]]; then
    die "pubspec 版本号格式应为 major.minor.patch+build，当前为: $old_version"
  fi

  old_major="$(decimal "${BASH_REMATCH[1]}")"
  old_minor="$(decimal "${BASH_REMATCH[2]}")"
  old_patch="$(decimal "${BASH_REMATCH[3]}")"
  old_build="$(decimal "${BASH_REMATCH[4]}")"
  new_build=$((old_build + 1))

  if [ -z "$requested_version" ]; then
    printf '%d.%d.%d+%d\n' \
      "$old_major" "$old_minor" "$((old_patch + 1))" "$new_build"
    return
  fi

  if [[ ! "$requested_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(\+([0-9]+))?$ ]]; then
    die "--version 格式应为 major.minor.patch 或 major.minor.patch+build: $requested_version"
  fi

  new_major="$(decimal "${BASH_REMATCH[1]}")"
  new_minor="$(decimal "${BASH_REMATCH[2]}")"
  new_patch="$(decimal "${BASH_REMATCH[3]}")"
  if [ -n "${BASH_REMATCH[5]:-}" ]; then
    new_build="$(decimal "${BASH_REMATCH[5]}")"
  fi

  printf '%d.%d.%d+%d\n' "$new_major" "$new_minor" "$new_patch" "$new_build"
}

update_pubspec_version() {
  local file="$1"
  local new_version="$2"
  local tmp_file

  tmp_file="$(mktemp "${file}.XXXXXX")"
  cp -p "$file" "$tmp_file"
  if ! awk -v version="$new_version" '
    BEGIN { replaced = 0 }
    /^version:[[:space:]]*/ && replaced == 0 {
      print "version: " version
      replaced = 1
      next
    }
    { print }
    END { if (replaced == 0) exit 2 }
  ' "$file" > "$tmp_file"; then
    rm -f "$tmp_file"
    die "更新版本号失败，未找到 version 字段: $file"
  fi
  mv "$tmp_file" "$file"
}

print_plan() {
  local old_version="$1"
  local new_version="$2"
  local tag_name="$3"

  echo ""
  echo "发布计划"
  echo "  远程仓库: $REMOTE"
  echo "  分支流向: $SOURCE_BRANCH -> $TARGET_BRANCH"
  echo "  版本变更: $old_version -> $new_version"
  echo "  发布标签: $tag_name"
  echo ""
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      require_option_value "$1" "${2:-}"
      REQUESTED_VERSION="$2"
      shift 2
      ;;
    --source)
      require_option_value "$1" "${2:-}"
      SOURCE_BRANCH="$2"
      shift 2
      ;;
    --target)
      require_option_value "$1" "${2:-}"
      TARGET_BRANCH="$2"
      shift 2
      ;;
    --remote)
      require_option_value "$1" "${2:-}"
      REMOTE="$2"
      shift 2
      ;;
    --pubspec)
      require_option_value "$1" "${2:-}"
      PUBSPEC_FILE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -y|--yes)
      YES=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数: $1"
      ;;
  esac
done

require_command git
require_command awk
require_command mktemp
require_command cp

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "当前目录不在 Git 仓库中"
cd "$REPO_ROOT"

case "$PUBSPEC_FILE" in
  /*) die "--pubspec 必须是仓库内的相对路径" ;;
esac
PUBSPEC_FILE="${PUBSPEC_FILE#./}"

[ "$SOURCE_BRANCH" != "$TARGET_BRANCH" ] || die "源分支和目标分支不能相同"
git check-ref-format --branch "$SOURCE_BRANCH" >/dev/null 2>&1 || die "无效的源分支: $SOURCE_BRANCH"
git check-ref-format --branch "$TARGET_BRANCH" >/dev/null 2>&1 || die "无效的目标分支: $TARGET_BRANCH"
git remote get-url "$REMOTE" >/dev/null 2>&1 || die "未配置 Git 远程: $REMOTE"
git ls-files --error-unmatch "$PUBSPEC_FILE" >/dev/null 2>&1 || die "pubspec 文件未被 Git 跟踪: $PUBSPEC_FILE"

if [ "$DRY_RUN" = true ]; then
  SOURCE_REF="$(resolve_branch_ref "$SOURCE_BRANCH")" || die "找不到源分支: $SOURCE_BRANCH"
  TARGET_REF="$(resolve_branch_ref "$TARGET_BRANCH")" || die "找不到目标分支: $TARGET_BRANCH"
  OLD_VERSION="$(read_version_from_ref "$SOURCE_REF" "$PUBSPEC_FILE")" || die "无法读取版本号: $SOURCE_REF:$PUBSPEC_FILE"
  NEW_VERSION="$(calculate_version "$OLD_VERSION" "$REQUESTED_VERSION")"
  TAG_NAME="v${NEW_VERSION%%+*}"

  git show-ref --verify --quiet "refs/tags/$TAG_NAME" && die "标签已存在: $TAG_NAME"
  git merge-base --is-ancestor "$TARGET_REF" "$SOURCE_REF" ||
    die "$SOURCE_BRANCH 无法快进合并到 $TARGET_BRANCH"

  echo "DRY-RUN：未联网，也不会修改文件或 Git 状态；远程引用以本地缓存为准。"
  print_plan "$OLD_VERSION" "$NEW_VERSION" "$TAG_NAME"
  echo "  git fetch $REMOTE --prune --tags"
  echo "  更新 $PUBSPEC_FILE 中的版本号为 $NEW_VERSION"
  echo "  git commit -m \"chore(release): $NEW_VERSION\" -- $PUBSPEC_FILE"
  echo "  git merge --ff-only $SOURCE_BRANCH"
  echo "  git tag -a $TAG_NAME -m \"Release $TAG_NAME\""
  echo "  git push --atomic --set-upstream $REMOTE \\"
  echo "    refs/heads/$SOURCE_BRANCH:refs/heads/$SOURCE_BRANCH \\"
  echo "    refs/heads/$TARGET_BRANCH:refs/heads/$TARGET_BRANCH \\"
  echo "    refs/tags/$TAG_NAME:refs/tags/$TAG_NAME"
  exit 0
fi

if [ -n "$(git status --porcelain)" ]; then
  git status --short
  die "当前工作区不干净，请先提交现有改动"
fi

run git fetch "$REMOTE" --prune --tags
RETURN_TO_SOURCE_ON_ERROR=true
trap handle_exit EXIT

SOURCE_REF="$(resolve_branch_ref "$SOURCE_BRANCH")" || die "远程和本地都找不到源分支: $SOURCE_BRANCH"
TARGET_REF="$(resolve_branch_ref "$TARGET_BRANCH")" || die "远程和本地都找不到目标分支: $TARGET_BRANCH"

if ! local_branch_exists "$SOURCE_BRANCH"; then
  run git branch --track "$SOURCE_BRANCH" "$SOURCE_REF"
fi
run git checkout "$SOURCE_BRANCH"
if remote_branch_exists "$SOURCE_BRANCH"; then
  run git pull --ff-only "$REMOTE" "$SOURCE_BRANCH"
else
  echo "提示: $REMOTE/$SOURCE_BRANCH 尚不存在，将在本次发布时创建。"
fi

if ! local_branch_exists "$TARGET_BRANCH"; then
  run git branch --track "$TARGET_BRANCH" "$TARGET_REF"
fi
run git checkout "$TARGET_BRANCH"
if remote_branch_exists "$TARGET_BRANCH"; then
  run git pull --ff-only "$REMOTE" "$TARGET_BRANCH"
fi
run git checkout "$SOURCE_BRANCH"

git merge-base --is-ancestor "$TARGET_BRANCH" "$SOURCE_BRANCH" ||
  die "$SOURCE_BRANCH 无法快进合并到 $TARGET_BRANCH，请先处理分支差异"

OLD_VERSION="$(read_version "$PUBSPEC_FILE")" || die "无法读取版本号: $PUBSPEC_FILE"
NEW_VERSION="$(calculate_version "$OLD_VERSION" "$REQUESTED_VERSION")"
[ "$NEW_VERSION" != "$OLD_VERSION" ] || die "新版本号不能与当前版本相同: $NEW_VERSION"
TAG_NAME="v${NEW_VERSION%%+*}"

git show-ref --verify --quiet "refs/tags/$TAG_NAME" && die "标签已存在: $TAG_NAME"

print_plan "$OLD_VERSION" "$NEW_VERSION" "$TAG_NAME"

update_pubspec_version "$PUBSPEC_FILE" "$NEW_VERSION"
run git diff --check -- "$PUBSPEC_FILE"
run git diff -- "$PUBSPEC_FILE"
run git add "$PUBSPEC_FILE"
run git commit -m "chore(release): $NEW_VERSION" -- "$PUBSPEC_FILE"

run git checkout "$TARGET_BRANCH"
run git merge --ff-only "$SOURCE_BRANCH"
run git tag -a "$TAG_NAME" -m "Release $TAG_NAME"

run git push --atomic --set-upstream "$REMOTE" \
  "refs/heads/$SOURCE_BRANCH:refs/heads/$SOURCE_BRANCH" \
  "refs/heads/$TARGET_BRANCH:refs/heads/$TARGET_BRANCH" \
  "refs/tags/$TAG_NAME:refs/tags/$TAG_NAME"

run git checkout "$SOURCE_BRANCH"

echo "发布完成: $OLD_VERSION -> $NEW_VERSION ($TAG_NAME)"
