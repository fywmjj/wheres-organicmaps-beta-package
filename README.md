# Where's Organic Maps Beta Package?

这是一个自动化项目，旨在解决直接从 Organic Maps 的 GitHub Actions 中下载 beta 版本 APK 包不便的问题。

许多用户，特别是那些无法访问或不便使用 Firebase App Distribution 的用户，希望能有一个稳定、直接的下载链接。本项目通过 GitHub Actions 实现了这一目标。

## ✨ 功能

- **自动同步**: 每隔 5 分钟，自动检查 [Organic Maps 的 beta 构建流程](https://github.com/organicmaps/organicmaps/actions/workflows/android-beta.yaml)。
- **获取最新版本**: 定位到最新一次成功的构建任务。
- **解析下载链接**: 从构建日志中提取出临时的 Firebase APK 下载链接。
- **永久存档**: 下载该 APK 文件，并将其上传到本项目的 **[Releases](https://github.com/YOUR_USERNAME/wheres-organicmaps-beta-package/releases)** 页面。
- **保持最新**: 新发布的 APK 会被标记为 "Latest"，确保你总能轻松找到最新版。

## 📥 如何使用？

你不需要做任何事情！直接访问本项目的 **[Releases 页面](https://github.com/YOUR_USERNAME/wheres-organicmaps-beta-package/releases)** 即可查看并下载所有已存档的 beta 版本 APK。

[![Sync Beta APK](https://github.com/YOUR_USERNAME/wheres-organicmaps-beta-package/actions/workflows/sync.yml/badge.svg)](https://github.com/YOUR_USERNAME/wheres-organicmaps-beta-package/actions/workflows/sync.yml)

## 🔧 如何自行部署 (For Developers)

如果你想自己搭建一个这样的仓库，请按以下步骤操作：

1.  **Fork 本仓库**。
2.  **生成 Personal Access Token (PAT)**:
    - 前往你的 GitHub [开发者设置页面](https://github.com/settings/tokens?type=beta)。
    - 生成一个新的 **classic** PAT。
    - 授予 `repo` 和 `workflow` 权限。`repo` 权限用于创建 Release，`workflow` 权限用于读取 Organic Maps 项目的 Actions 信息。
    - **务必复制并妥善保管好这个 Token**，因为页面刷新后你将无法再次看到它。
3.  **在你的仓库中设置 Secrets**:
    - 前往你 Fork 后的仓库，点击 `Settings` > `Secrets and variables` > `Actions`。
    - 点击 `New repository secret`。
    - 创建一个名为 `GH_PAT` 的 Secret，将其值设置为你刚刚生成的 Personal Access Token。
4.  **启用 Actions**:
    - 前往仓库的 `Actions` 标签页，如果 Actions 被禁用了，请点击按钮启用它。
    - 工作流将根据预设的计划（每5分钟）自动运行，或者你也可以手动触发它。

---

*本项目与 Organic Maps 官方没有直接关联，仅作为一个方便社区用户的工具。*
