#!/bin/bash

# 如果任何命令失败，立即退出
set -e
# 管道中的任何命令失败，都视为整个管道失败
set -o pipefail

echo "INFO: Starting the sync process for Organic Maps beta..."

# --- 配置 ---
REMOTE_REPO="organicmaps/organicmaps"
WORKFLOW_FILE="android-beta.yaml"
RELEASE_NOTES_URL="https://raw.githubusercontent.com/organicmaps/organicmaps/master/android/app/src/fdroid/play/listings/en-US/release-notes.txt"
CURRENT_REPO="$REPO"
# [新] Firebase 链接的有效期（秒），用于时间检查
LINK_EXPIRATION_SECONDS=3600 # 1 hour
# [新] Organic Maps Beta APK 在 Artifact 中的名称
ARTIFACT_NAME="fdroid-beta"

# --- 脚本临时文件 ---
RELEASE_NOTES_FILENAME="release_notes.txt"
# [新] 用于解压 Artifact 的临时目录
ARTIFACT_DIR=$(mktemp -d)

# 清理函数，确保无论脚本成功或失败，临时文件和目录都会被删除
cleanup() {
  echo "INFO: Cleaning up temporary files and directories..."
  rm -f "${RELEASE_NOTES_FILENAME}"
  # -rf 确保即使目录非空也能被删除
  rm -rf "${ARTIFACT_DIR}"
}
# 设置 trap，在脚本退出时（无论是正常退出、出错还是被中断）执行 cleanup 函数
trap cleanup EXIT

# 1. [MODIFIED] 获取最新的成功构建信息（ID 和更新时间）
echo "INFO: Fetching the latest successful run from ${REMOTE_REPO}..."
RUN_INFO=$(gh run list --repo "${REMOTE_REPO}" --workflow "${WORKFLOW_FILE}" --json databaseId,conclusion,updatedAt --jq '.[] | select(.conclusion=="success") | .' | head -n 1)

if [ -z "$RUN_INFO" ]; then
  echo "ERROR: Could not find any successful runs for workflow '${WORKFLOW_FILE}'. Exiting."
  exit 1
fi

LATEST_RUN_ID=$(echo "$RUN_INFO" | jq -r '.databaseId')
RUN_UPDATED_AT=$(echo "$RUN_INFO" | jq -r '.updatedAt')
echo "INFO: Found latest successful run ID: ${LATEST_RUN_ID}, completed at: ${RUN_UPDATED_AT}"

# 2. 生成唯一的 Release 标签和标题
RELEASE_TITLE=$(gh run view "${LATEST_RUN_ID}" --repo "${REMOTE_REPO}" --json displayTitle --jq '.displayTitle')
TAG_NAME=$(echo "${RELEASE_TITLE}" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/-/g' -e 's/--\+/-/g' -e 's/^-//' -e 's/-$//')
TAG_NAME="${TAG_NAME}-${LATEST_RUN_ID}"

echo "INFO: Generated release title: '${RELEASE_TITLE}'"
echo "INFO: Generated tag name: '${TAG_NAME}'"

# 3. 检查这个 Release 是否已经存在
echo "INFO: Checking if release with tag '${TAG_NAME}' already exists..."
if gh release view "${TAG_NAME}" --repo "${CURRENT_REPO}" > /dev/null 2>&1; then
  echo "INFO: Release '${TAG_NAME}' already exists. Nothing to do. Exiting."
  exit 0
else
  echo "INFO: Release '${TAG_NAME}' does not exist. Proceeding..."
fi

# 4. [NEW] 核心逻辑：优先下载 Artifact，失败则回退到解析日志
APK_FILE_PATH="" # 初始化 APK 文件路径变量

echo "INFO: Attempting to download artifact '${ARTIFACT_NAME}' from run ${LATEST_RUN_ID}..."
if gh run download "${LATEST_RUN_ID}" --repo "${REMOTE_REPO}" -n "${ARTIFACT_NAME}" -D "${ARTIFACT_DIR}"; then
  echo "INFO: Artifact downloaded successfully to temporary directory."
  
  # 在解压目录中查找 APK 文件
  APK_FILE_PATH=$(find "${ARTIFACT_DIR}" -type f -name "OrganicMaps-*-beta.apk" | head -n 1)
  
  if [ -n "$APK_FILE_PATH" ]; then
    echo "INFO: Found APK file in artifact: ${APK_FILE_PATH}"
  else
    echo "WARNING: Artifact downloaded, but no APK file found inside. Will attempt fallback."
  fi
fi

# 5. [NEW] 如果通过 Artifact 未能获得 APK，则回退到解析日志（并进行时间检查）
if [ -z "$APK_FILE_PATH" ]; then
  echo "INFO: Fallback: Attempting to parse download link from log."
  
  # 时间检查逻辑
  RUN_TIMESTAMP=$(date -d "${RUN_UPDATED_AT}" +%s)
  CURRENT_TIMESTAMP=$(date +%s)
  AGE_SECONDS=$((CURRENT_TIMESTAMP - RUN_TIMESTAMP))

  echo "INFO: Run is ${AGE_SECONDS} seconds old."
  if [ "$AGE_SECONDS" -gt "$LINK_EXPIRATION_SECONDS" ]; then
    echo "WARNING: The latest successful run is older than 1 hour. The download link in the log has likely expired. Stopping execution to avoid creating an empty release."
    exit 0 # 正常退出，这不是一个错误
  fi

  # 解析日志获取 URL
  echo "INFO: Downloading log for run ID ${LATEST_RUN_ID} to find the APK URL..."
  APK_URL=$(gh run view "${LATEST_RUN_ID}" --repo "${REMOTE_REPO}" --log | grep -o 'https://firebaseappdistribution.googleapis.com[^[:space:]]*' | head -n 1)

  if [ -z "$APK_URL" ]; then
    echo "ERROR: Could not find the Firebase download URL in the log for run ${LATEST_RUN_ID}."
    exit 1
  fi
  echo "INFO: Found APK download URL."

  # 下载 APK 文件到临时目录
  TEMP_APK_FILENAME="${ARTIFACT_DIR}/organicmaps-beta.apk"
  echo "INFO: Downloading APK from Firebase..."
  curl --location --retry 3 --fail -o "${TEMP_APK_FILENAME}" "${APK_URL}"
  APK_FILE_PATH="${TEMP_APK_FILENAME}"
  echo "INFO: APK downloaded successfully as '${APK_FILE_PATH}'."
fi

# 6. 下载官方的 Release Notes 文件
echo "INFO: Downloading official release notes..."
curl --silent --location --retry 3 -o "${RELEASE_NOTES_FILENAME}" "${RELEASE_NOTES_URL}"
echo "INFO: Official release notes downloaded."

# 7. 创建 Release 并上传最终找到的 APK 文件
echo "INFO: Creating new release '${TAG_NAME}' and uploading the APK..."
gh release create "${TAG_NAME}" \
  --repo "${CURRENT_REPO}" \
  --title "${RELEASE_TITLE}" \
  --notes-file "${RELEASE_NOTES_FILENAME}" \
  --latest \
  "${APK_FILE_PATH}" # 使用变量引用 APK 路径

echo "SUCCESS: Release created and APK uploaded successfully!"
# 清理工作将由 trap 自动执行
