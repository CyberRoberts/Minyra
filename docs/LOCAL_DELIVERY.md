# Mini 酱本地 DMG 交付（实验性开发分支）

目标：开发任务由 Minyra 本地 AI Agent 修改和独立验收代码，随后由本机 Intel Mac 编译、测试、打包并验证 DMG。流程本身不调用 GitHub Actions 或 self-hosted runner。

## 本分支

- Mini 酱窗口增加本地交付面板：五段进度、日志、停止构建、Finder 定位。
- 「AI 验收通过后自动生成 QA DMG」需用户明确开启，默认关闭。
- 仅可执行已经核准、Git blob SHA 固定的 Ahaly 本地构建脚本 tools/minyra_selfhost_qa_dmg.sh。任何脚本更改都会阻止高权限执行，直到重新审阅。
- 不传入 Agent API Key、GitHub Token 等用户环境变量。每次构建使用唯一输出目录，避免覆盖。
- Ahaly 构建脚本执行：项目契约测试、Intel 原生编译、ad-hoc 签名、DMG 创建、DMG 检查、SHA256 校验。
- 只创建内部 QA DMG，不安装、不公证、不发布 Cloudflare R2 或 GitHub Releases。不触碰正式版。
- 打包报错会显示为失败，不会谎称交付成功。自动反馈错误并再次 AI 修复仍待实现。

## 首次使用

1. 用本分支源码编译 Mini 酱，必须先在真正的 Intel macOS 12 上验证自测、UI、DMG 路径。当前还不能称为已通过实机验收。
2. 在 Mini 酱里打开本地私人 Ahaly 仓库的根目录，需要包含 macos_stable 文件夹和 tools 目录。
3. 在 Mini 酱设置中启用允许本地测试和编译。仅对可信项目开启；本地 DMG 脚本使用当前 Mac 用户的权限，不属于系统级完全沙箱。
4. 第一次手动点「现在打包」进行 QA；通过后再打开自动交付开关。之后在 AI 任务独立验收通过时自动打包。
5. 成功 QA DMG 保存在 ~/MinyraRunnerBuilds/，可从 Mini 酱窗口在 Finder 打开。

## 止费设置

要真正停止 GitHub 云端计费，仍需在 CyberRoberts/Ahaly-for-Mac 以及其他私人仓库分别打开 Settings > Actions > General，停止不需要的云端工作流。同时在 Billing and licensing > Budgets and alerts 将 Actions 的超额预算设为 US$0 并启用可用的停止开关，检查 Usage 实际账单。

禁用云端 Actions 不影响本地 Git 开发、上传和下载源码，但会使远程 CI/CD 不再运行。这不是 Mini 酱应用能擅自替你完成的账号操作。

## 当前边界

- 只适用于 Ahaly 1.2.0 Build 121 内部 QA DMG 模板；其他项目的交付模板尚未完成。
- 脚本使用 Git HEAD 缩写命名，若有未提交源代码修改，文件名不会完整表达所有工作树内容。
- 目前没有 macOS 12 实机编译、 GUI 或签名/DMG 验收结论。不能把这个分支当作正式版发布。
- GitHub 的 Actions 工作流仍在仓库里，提交到 GitHub 仍可能触发原有付费云端工作流；上述止费设置必须另外执行。
