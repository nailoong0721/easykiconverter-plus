# EasyKiConverterPlus

EasyKiConverterPlus 在 [EasyKiConverter](https://github.com/EasyKiconverter/EasyKiConverter/) 基础上增加 Windows 下的 KiCad 库合并流程：先将 LCSC / EasyEDA 元件转换到临时目录，再预检查、备份并合并到选定的现有库。

[使用文章](https://nailoong0721.com/posts/easykiconverter-plus/) · [下载 Windows x64 程序](https://github.com/nailoong0721/easykiconverter-plus/releases/download/v2026.11.14/EasyKiConverterPlus-Windows-x64.zip) · [Release 与校验值](https://github.com/nailoong0721/easykiconverter-plus/releases/tag/v2026.11.14)

## Windows 使用

1. 从 Release 下载完整 ZIP，解压后运行 `EasyKiConverterPlus.exe`。
2. 保留同目录的 DLL、QML 插件和 `tools` 文件夹。
3. 安装 KiCad，在界面中确认当前电脑的 `kicad-cli.exe` 路径；程序包不包含 KiCad。
4. 先用少量元件执行普通导出并检查结果。直接合并到现有库时，选择同名配套的 `.kicad_sym` 文件和 `.pretty` 目录所在库，并保留程序报告的备份。

直接合并依赖 Windows PowerShell 5.1 与 KiCad CLI。转换后仍需核对引脚与焊盘编号、封装方向和尺寸、符号关联及 3D 模型路径。

## 源码结构与构建

- `src/`：C++ / Qt QML 程序，包括 `KiCadLibraryImportService` 与 Plus 界面修改。
- `tools/kicad-library-importer/`：预检查、备份、合并和 KiCad 校验脚本。
- `CMakeLists.txt`、`vcpkg.json`、`tools/`：上游构建配置和工具脚本。
- [EASYKICONVERTERPLUS.md](EASYKICONVERTERPLUS.md)：Plus 开发与构建记录。
- [README.upstream.md](README.upstream.md)、`docs/`：保留的上游使用和开发资料。

初始版本来自 2026-11-14 的公开源码快照，上游基线为 `f7ac474`，包含当时本机的 Plus 源码修改。Windows 打包记录使用 Qt 6.8.3 / MinGW 13.1.0；按当前机器调整 Qt、CMake 与 KiCad 路径，使用项目现有构建配置。上游文档中的下载入口和版本说明以其对应项目为准。

Release 的 Windows ZIP 保留用户提供的原始文件，源码 ZIP 保留此前网站分享快照；Git 仓库在该快照上增加本页和 Release 校验说明，并将一条手工测试记录中的用户目录改为通用示例路径。本次整理核对源码和压缩包完整性，没有重新构建程序或执行新的真实元件转换回归。

## 许可与相关工具

本项目遵循 [GPL-3.0 LICENSE](LICENSE)，保留上游及源码中的版权声明。发行包附同版本源码快照，后续修订可在 Git 提交中追踪。

电路绘图、专利与论文写作 Skill 统一放在 [codex-skills](https://github.com/nailoong0721/codex-skills) 仓库。
