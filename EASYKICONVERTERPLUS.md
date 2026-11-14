# EasyKiConverterPlus

基于 EasyKiConverter 的 Windows 桌面版本，将 KiCadLibraryImporter 的库合并流程接入转换界面。

## 启动

本次本地构建的独立程序位于：

`E:\20260929_kicad_tools_opt\Releases\EasyKiConverterPlus-Windows-x64\EasyKiConverterPlus.exe`

请保留程序目录内的 DLL、QML 插件和 `tools` 目录，直接启动上述程序。

## 直接转换并合并

1. 选择 KiCad 目标格式，在左侧“KiCad 直接导入（Windows）”中启用“直接合并到现有库”。
2. 选择目标库的 `.kicad_sym` 文件或 `.pretty` 目录。两者需要在同一目录中，名称相同，例如 `MyLibrary.kicad_sym` 与 `MyLibrary.pretty`。
3. 如需复用目标库已有的同名封装，开启“复用同名封装”。未开启时，同名封装冲突会停止合并。
4. 本机 KiCad CLI 为 `D:\Kicad\bin\kicad-cli.exe`。如果没有自动找到，在“选择 CLI”中指定它。
5. 输入立创 C 编号，或者导入 BOM 后点击“开始转换”。程序先转换到临时目录，再执行预检查、合并和 KiCad 校验。完成状态会提供备份目录。

关闭直接合并开关后，继续使用原有的普通导出流程。直接合并目前仅支持 Windows，依赖 Windows PowerShell 5.1 和 KiCad CLI。

## 本地构建环境

- CMake：`D:\CMake\bin\cmake.exe`
- Qt：`D:\Qt6\6.8.3\mingw_64`
- 匹配的编译器：`D:\Qt6\Tools\mingw1310_64\bin\g++.exe`，MinGW 13.1.0
- Ninja：`D:\CMake\bin\ninja.exe`

Qt 的 MinGW 运行库必须与构建工具链匹配。本次使用 Qt 配套的 MinGW 13.1.0。

## 上游与许可

EasyKiConverter 上游项目：https://github.com/EasyKiconverter/EasyKiConverter/

保留上游版权声明和 GPL-3.0 许可证，完整许可证见 `LICENSE`。此目录中的源代码包含 Plus 的界面、视图模型以及库合并脚本。
