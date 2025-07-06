#!/bin/bash

# 如果任何命令失败，立即退出
set -e
# 管道中的任何命令失败，都视为整个管道失败
set -o pipefail

echo "INFO: Starting the sync process for Organic Maps beta..."

# --- 配置 ---
REMOTE_REPO="organicmaps/organicmaps"
WORKFLOW_FILE="android-beta.yaml"
# 注意：master 分支可能会变为 main，但目前还是 master
RELEASE_NOTES_URL="https://raw.githubusercontent.com/organicmaps/organicmaps/master/android/app/src/fdroid/play/listings/en-US/release-notes.txt"
CURRENT_REPO="$REPO"

# --- 脚本临时文件名 ---
APK_FILENAME="organicmaps-beta.apk"
RELEASE_NOTES_FILENAME="release_notes.txt"

# 1. 使用 GitHub CLI 获取 Organic Maps 仓库最新一次成功的 beta 构建任务的 ID
echo "INFO: Fetching the latest successful run ID from ${REMOTE_REPO}..."
LATEST_RUN_ID=$(gh run list --repo "${REMOTE_REPO}" --workflow "${WORKFLOW_FILE}" --json databaseId,status --jq '.[] | select(.status=="success") | .databaseId' | head -n 1)

if [ -z "$LATEST_RUN_ID" ]; then
  echo "ERROR: Could not find any successful runs for workflow '${WORKFLOW_FILE}'. Exiting."
  exit 1
fi
echo "INFO: Found latest successful run ID: ${LATEST_RUN_ID}"

# 2. 根据运行 ID 获取其显示标题，并创建一个唯一的、URL友好的标签名
RELEASE_TITLE=$(gh run view "${LATEST_RUN_ID}" --repo "${REMOTE_REPO}" --json displayTitle --jq '.displayTitle')
TAG_NAME=$(echo "${RELEASE_TITLE}" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/-/g' -e 's/--\+/-/g' -e 's/^-//' -e 's/-$//')

echo "INFO: Generated release title: '${RELEASE_TITLE}'"
echo "INFO: Generated tag name: '${TAG_NAME}'"

# 3. 检查这个标签的 Release 是否已经存在于我们的仓库中
echo "INFO: Checking if release with tag '${TAG_NAME}' already exists..."
if gh release view "${TAG_NAME}" --repo "${CURRENT_REPO}" > /dev/null 2>&1; then
  echo "INFO: Release '${TAG_NAME}' already exists in this repository. Nothing to do. Exiting."
  exit 0
else
  echo "INFO: Release '${TAG_NAME}' does not exist. Proceeding to download and upload."
fi

# 4. 下载该次运行的日志，并从中提取出 Firebase 的 APK 下载链接
echo "INFO: Downloading log for run ID ${LATEST_RUN_ID} to find the APK URL..."
APK_URL=$(gh run view "${LATEST_RUN_ID}" --repo "${REMOTE_REPO}" --log | grep -o 'https://firebaseappdistribution.googleapis.com[^[:space:]]*')

if [ -z "$APK_URL" ]; then
  echo "ERROR: Could not find the Firebase download URL in the log for run ${LATEST_RUN_ID}. The log format might have changed."
  exit 1
fi
echo "INFO: Found APK download URL."

# 5. 使用 curl 下载 APK 文件
echo "INFO: Downloading APK from Firebase..."
curl --location --retry 3 --output "${APK_FILENAME}" "${APK_URL}"
echo "INFO: APK downloaded successfully as '${APK_FILENAME}'."

# 6. 【新功能】下载官方的 Release Notes 文件
echo "INFO: Downloading official release notes from Organic Maps repository..."
curl --silent --location --retry 3 --output "${RELEASE_NOTES_FILENAME}" "${RELEASE_NOTES_URL}"
echo "INFO: Official release notes downloaded successfully as '${RELEASE_NOTES_FILENAME}'."

# 7. 使用 GitHub CLI 在我们自己的仓库中创建新的 Release，并上传 APK
#    使用 --notes-file 参数来指定包含发布说明的文件
echo "INFO: Creating new release '${TAG_NAME}' and uploading the APK..."
gh release create "${TAG_NAME}" \
  --repo "${CURRENT_REPO}" \
  --title "${RELEASE_TITLE}" \
  --notes-file "${RELEASE_NOTES_FILENAME}" \
  --latest \
  "${APK_FILENAME}"

echo "INFO: Release created and APK uploaded successfully!"

# 8. 清理下载的临时文件
rm "${APK_FILENAME}" "${RELEASE_NOTES_FILENAME}"
echo "INFO: Cleanup complete. Sync process finished."
