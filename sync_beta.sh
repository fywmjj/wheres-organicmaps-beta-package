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
LINK_EXPIRATION_SECONDS=3600
ARTIFACT_NAME="fdroid-beta"

# --- 脚本临时文件 ---
RELEASE_NOTES_FILENAME="release_notes.txt"
ARTIFACT_DIR=$(mktemp -d)

# 清理函数
cleanup() {
  echo "INFO: Cleaning up temporary files and directories..."
  rm -f "${RELEASE_NOTES_FILENAME}"
  rm -rf "${ARTIFACT_DIR}"
}
trap cleanup EXIT

# 1. [MODIFIED & FIXED] 获取最新的成功构建信息
#    【修正】使用 --limit 1 代替 | head -n 1 来避免 SIGPIPE (退出码 141) 错误。
echo "INFO: Fetching the latest successful run from ${REMOTE_REPO}..."
RUN_INFO=$(gh run list --repo "${REMOTE_REPO}" --workflow "${WORKFLOW_FILE}" --limit 1 --json databaseId,conclusion,updatedAt --jq '.[] | select(.conclusion=="success")')

if [ -z "$RUN_INFO" ]; then
  # 这一行现在可能永远不会被触发，因为 --limit 1 会确保在找不到成功 run 时 RUN_INFO 为空，而不是命令失败
  echo "INFO: No recent successful run found for workflow '${WORKFLOW_FILE}'. Nothing to do. Exiting."
  exit 0
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

# 4. 核心逻辑：优先下载 Artifact，失败则回退到解析日志
APK_FILE_PATH=""

echo "INFO: Attempting to download artifact '${ARTIFACT_NAME}' from run ${LATEST_RUN_ID}..."
if gh run download "${LATEST_RUN_ID}" --repo "${REMOTE_REPO}" -n "${ARTIFACT_NAME}" -D "${ARTIFACT_DIR}"; then
  echo "INFO: Artifact downloaded successfully to temporary directory."
  
  APK_FILE_PATH=$(find "${ARTIFACT_DIR}" -type f -name "OrganicMaps-*-beta.apk" | head -n 1)
  
  if [ -n "$APK_FILE_PATH" ]; then
    echo "INFO: Found APK file in artifact: ${APK_FILE_PATH}"
  else
    echo "WARNING: Artifact downloaded, but no APK file found inside. Will attempt fallback."
  fi
fi

# 5. 如果通过 Artifact 未能获得 APK，则回退到解析日志（并进行时间检查）
if [ -z "$APK_FILE_PATH" ]; then
  echo "INFO: Fallback: Attempting to parse download link from log."
  
  RUN_TIMESTAMP=$(date -d "${RUN_UPDATED_AT}" +%s)
  CURRENT_TIMESTAMP=$(date +%s)
  AGE_SECONDS=$((CURRENT_TIMESTAMP - RUN_TIMESTAMP))

  echo "INFO: Run is ${AGE_SECONDS} seconds old."
  if [ "$AGE_SECONDS" -gt "$LINK_EXPIRATION_SECONDS" ]; then
    echo "WARNING: The latest successful run is older than 1 hour. The download link in the log has likely expired. Stopping execution to avoid creating an empty release."
    exit 0
  fi

  echo "INFO: Downloading log for run ID ${LATEST_RUN_ID} to find the APK URL..."
  APK_URL=$(gh run view "${LATEST_RUN_ID}" --repo "${REMOTE_REPO}" --log | grep -o 'https://firebaseappdistribution.googleapis.com[^[:space:]]*' | head -n 1)

  if [ -z "$APK_URL" ]; then
    echo "ERROR: Could not find the Firebase download URL in the log for run ${LATEST_RUN_ID}."
    exit 1
  fi
  echo "INFO: Found APK download URL."

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
  "${APK_FILE_PATH}"

echo "SUCCESS: Release created and APK uploaded successfully!"
