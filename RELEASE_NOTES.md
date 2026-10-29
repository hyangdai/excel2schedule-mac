# 公开发布准备记录

版本：1.3（构建 4）  
整理日期：2026-10-29

## 保留的内容

当前应用、桌面小组件、图标、Xcode 工程、共享 scheme、配置生成脚本及自动化测试。Excel 实时同步、完成标记写回、备份和撤销功能保持现有实现。

## 隐私清理

- 首次启动不预设 Excel 文件；由使用者自行选择，未选择时显示引导。
- 移除个人文件路径、原表名称、README 中的真实日程和本机使用记录。
- 移除开发者签名团队标识，将 Bundle Identifier 和 App Group 统一改为 `com.example` 示例标识；配置生成脚本同步处理。
- 测试不再访问个人工作簿，相关事项文字替换为通用示例。
- 不包含本地快照、书签、完成记录、表格与备份、构建产物、缓存、旧版本归档、Xcode 用户状态或 Git 历史。
- 扩充 `.gitignore`，避免将本地数据、签名文件和压缩包加入仓库。

## 上传 GitHub

将本目录作为仓库根目录。先在 GitHub 创建空仓库，再在本目录执行：

```sh
git init -b main
git add .
git diff --cached --stat
git commit -m "Prepare TodaySchedule 1.3 source release"
git remote add origin https://github.com/YOUR_USERNAME/TodaySchedule.git
git push -u origin main
```

请先将示例地址替换为自己的仓库地址。上传前确认本机 Git 作者姓名、邮箱符合自己的隐私偏好。压缩包和校验文件已被忽略，无需上传到源码仓库。

当前没有添加 LICENSE；许可证由项目所有者自行决定。

## 本次验证

- 在清理后的发布副本上运行 `bash scripts/test.sh`，全部通过；覆盖读取、日期、完成状态、Excel 写回、撤销及实时同步逻辑。
- Xcode Debug 构建通过（关闭代码签名，仅验证应用和小组件编译；实际运行仍需配置自己的签名）。
- 配置文件、配置生成脚本、脚本语法及发布文件敏感信息扫描通过。
- 校验原始源码摘要，确认原项目未被修改。
- 本次未运行需要实际控制 Microsoft Excel 的可选联调脚本，也未验证新的签名配置下的桌面组件运行。

本目录提供源码及源码压缩包，没有预编译的应用安装包；尚未创建或推送远程 GitHub 仓库。
