#!/bin/bash

set -e
set -o pipefail

echo "INFO: Starting the sync process for Organic Maps beta..."

# --- 配置 ---
REMOTE_REPO="organicmaps/organicmaps"
WORKFLOW_FILE="android-beta.yaml"
CURRENT_REPO="$REPO"
LINK_EXPIRATION_SECONDS=3600
PREFERRED_ARTIFACT_NAMES=("fdroid-beta" "google-beta")

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

# 1. 获取最新的成功构建信息
echo "INFO: Fetching the latest successful run from ${REMOTE_REPO}..."
RUN_INFO=$(gh run list --repo "${REMOTE_REPO}" --workflow "${WORKFLOW_FILE}" --limit 1 --json databaseId,conclusion,updatedAt --jq '.[] | select(.conclusion=="success")')

if [ -z "$RUN_INFO" ]; then
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

# 4. 循环尝试下载优先列表中的 Artifact
APK_FILE_PATH=""
for ARTIFACT_NAME in "${PREFERRED_ARTIFACT_NAMES[@]}"; do
    echo "INFO: Attempting to download artifact '${ARTIFACT_NAME}' from run ${LATEST_RUN_ID}..."
    
    if gh run download "${LATEST_RUN_ID}" --repo "${REMOTE_REPO}" -n "${ARTIFACT_NAME}" -D "${ARTIFACT_DIR}"; then
        echo "INFO: Artifact '${ARTIFACT_NAME}' downloaded successfully."
        echo "INFO: Searching for APK with specific pattern inside the artifact..."
        APK_FILE_PATH=$(find "${ARTIFACT_DIR}" -type f | grep -E '/OrganicMaps-[0-9]{8}-[a-z]+-beta\.apk$' | head -n 1)
        
        if [ -n "$APK_FILE_PATH" ]; then
            echo "INFO: Found matching APK file: ${APK_FILE_PATH}"
            break
        else
            echo "WARNING: Artifact downloaded, but no APK matching the pattern was found. Trying next name..."
        fi
    else
        echo "INFO: Artifact '${ARTIFACT_NAME}' not found. Trying next name..."
    fi
done

# 5. 如果循环结束后仍未找到 APK，则回退到解析日志
if [ -z "$APK_FILE_PATH" ]; then
    echo "INFO: No suitable artifact found. Falling back to parsing download link from log."
  
    RUN_TIMESTAMP=$(date -d "${RUN_UPDATED_AT}" +%s)
    CURRENT_TIMESTAMP=$(date +%s)
    AGE_SECONDS=$((CURRENT_TIMESTAMP - RUN_TIMESTAMP))

    echo "INFO: Run is ${AGE_SECONDS} seconds old."
    if [ "$AGE_SECONDS" -gt "$LINK_EXPIRATION_SECONDS" ]; then
        echo "WARNING: Latest run is older than 1 hour. Log link expired. Stopping."
        exit 0
    fi

    echo "INFO: Downloading log for run ID ${LATEST_RUN_ID} to find the APK URL..."
    APK_URL=$(gh run view "${LATEST_RUN_ID}" --repo "${REMOTE_REPO}" --log | grep -o 'https://firebaseappdistribution.googleapis.com[^[:space:]]*' | head -n 1)

    if [ -z "$APK_URL" ]; then
        echo "ERROR: Could not find the Firebase download URL in the log."
        exit 1
    fi
    echo "INFO: Found APK download URL."

    TEMP_APK_FILENAME="${ARTIFACT_DIR}/organicmaps-beta.apk"
    echo "INFO: Downloading APK from Firebase..."
    curl --location --retry 3 --fail -o "${TEMP_APK_FILENAME}" "${APK_URL}"
    APK_FILE_PATH="${TEMP_APK_FILENAME}"
    echo "INFO: APK downloaded successfully as '${APK_FILE_PATH}'."
fi

# 6. 【全新的 Release Notes 生成逻辑】
echo "INFO: Generating multi-language release notes..."

# 创建临时文件保存 release notes
echo "" > "${RELEASE_NOTES_FILENAME}"

# 添加标题
echo "# Organic Maps Beta Release" >> "${RELEASE_NOTES_FILENAME}"
echo "### Release ID: ${LATEST_RUN_ID}" >> "${RELEASE_NOTES_FILENAME}"
echo "### Date: $(date -u "+%Y-%m-%d %H:%M:%S UTC")" >> "${RELEASE_NOTES_FILENAME}"
echo "" >> "${RELEASE_NOTES_FILENAME}"
echo "## Release Notes in Multiple Languages" >> "${RELEASE_NOTES_FILENAME}"
echo "" >> "${RELEASE_NOTES_FILENAME}"

# 使用GitHub API查询仓库中所有可用的语言版本release notes
echo "INFO: Looking for release notes in all available languages..."
API_BASE="https://api.github.com/repos/${REMOTE_REPO}/contents/android/app/src/google/play/release-notes"
LANG_DIRS=$(curl -s -H "Authorization: token ${GH_TOKEN}" "${API_BASE}" | jq -r '.[] | select(.type=="dir") | .name')

if [ -z "${LANG_DIRS}" ]; then
    echo "WARNING: Could not find any language directories for release notes. Using fallback."
    # 添加一个说明
    echo "**Note:** Could not retrieve release notes from repository." >> "${RELEASE_NOTES_FILENAME}"
    echo "Please check [Organic Maps website](https://organicmaps.app/) for the latest changes." >> "${RELEASE_NOTES_FILENAME}"
else
    # 对于每种语言，获取release notes并添加到输出
    for LANG in ${LANG_DIRS}; do
        echo "INFO: Getting release notes for language: ${LANG}..."
        NOTE_URL="https://raw.githubusercontent.com/${REMOTE_REPO}/master/android/app/src/google/play/release-notes/${LANG}/default.txt"
        NOTE_CONTENT=$(curl -s "${NOTE_URL}")
        
        if [ -n "${NOTE_CONTENT}" ]; then
            echo "### <${LANG}>" >> "${RELEASE_NOTES_FILENAME}"
            echo "${NOTE_CONTENT}" >> "${RELEASE_NOTES_FILENAME}"
            echo "### </${LANG}>" >> "${RELEASE_NOTES_FILENAME}"
            echo "" >> "${RELEASE_NOTES_FILENAME}"
        fi
    done
fi

echo "INFO: Multi-language release notes generated successfully."

# 7. 创建 Release 并上传最终找到的 APK 文件
echo "INFO: Creating new release '${TAG_NAME}' and uploading the APK..."
gh release create "${TAG_NAME}" \
  --repo "${CURRENT_REPO}" \
  --title "${RELEASE_TITLE}" \
  --notes-file "${RELEASE_NOTES_FILENAME}" \
  --latest \
  "${APK_FILE_PATH}"

echo "SUCCESS: Release created and APK uploaded successfully!"
