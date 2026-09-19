# CustomSoundpad
1.灵感来源: https://github.com/Mug1vara97/UniteFx  
## AI  Content:
1.InjectAudioApo 由人类编写  
2.InjectAudioApo.ApoTester + Setup由ai完成  
3.frontend + build.ps1 由AI编写(我不会前端...)  
4.test.wav为 [连烦恼也融入天空 -- 塞壬唱片-MSR](https://monster-siren.hypergryph.com/music/514591)  (真的很好听)  
下为ai生成 我不擅长文书
## Start 
Windows 平台的注入式音效板（Soundpad）项目：Godot 4 C# 前端 + C++ GDExtension + Windows APO 音频处理驱动。

本仓库是**聚合仓库（meta repo）**，本身不含源码，只通过 `git submodule` 引用两个子仓库。

## 仓库结构

| 路径 | 子仓库 | 内容 |
| --- | --- | --- |
| `CustomSoundpad_frontend/` | `killjsj/custom_soundpad_frontend` | Godot 4 项目 + C++ GDExtension 源码（`src/`、`project/`），自带 `godot-cpp` 子模块 |
| `InjectAudioApo/` | `killjsj/inject_audio_apo`| APO 驱动本体（C++/ATL）、`ApoTester` 测试程序、`Setup` 安装工程 |

远端地址：

- 本仓库（meta）：<https://github.com/killjsj/custom_soundpad.git>
- 前端：<https://github.com/killjsj/custom_soundpad_frontend.git>
- APO：<https://github.com/killjsj/inject_audio_apo.git>

## 克隆

```powershell
git clone --recurse-submodules https://github.com/killjsj/custom_soundpad.git
```

已经克隆、但子模块目录是空的：

```powershell
git submodule update --init --recursive
```

## 日常提交

### 方式一：一键脚本（推荐）

根目录的 `update.ps1` 会按正确顺序处理三个仓库：子仓库先提交推送，最后 meta 仓库记录新指针。

```powershell
.\update.ps1                                   # 用默认信息 "update: yyyy-MM-dd HH:mm"
.\update.ps1 "feat: 加入新的 APO 音效链"        # 指定提交信息
.\update.ps1 -DryRun                           # 只看会提交什么，不改动任何东西
.\update.ps1 "wip" -NoPush                     # 只提交，不推送
```

脚本行为：

1. 子模块未初始化时自动 `git submodule update --init`；
2. 每个仓库 `git add -A`，**有实际改动才提交**（只是子模块工作区脏、没有可提交内容时不会产生空提交）；
3. 推送被拒绝（远端有新提交）时自动 `git pull --rebase --autostash` 再重试一次；
4. meta 仓库只有子模块指针变化时，提交信息自动变成 `chore: bump submodules (...)`；
5. 如果嵌套子模块（`godot-cpp`）里有**被修改的已跟踪文件**，会给出提醒——它属于独立仓库，需要单独提交。

### 方式二：手动提交

子仓库是**独立仓库**，改动必须在子仓库里 commit + push，然后回到本仓库提交子模块指针：

```powershell
# 1) 改前端
cd CustomSoundpad_frontend
git add -A; git commit -m "feat: ..."; git push

# 2) 改 APO
cd ..\InjectAudioApo
git add -A; git commit -m "feat: ..."; git push

# 3) 回到 meta 仓库，记录新的子模块指针
cd ..
git add CustomSoundpad_frontend InjectAudioApo
git commit -m "chore: bump submodules"
git push
```

只提交指针时忘了 `git add` 对应目录，meta 仓库就不会指向新的提交。

## 构建

### 1. C++ GDExtension（前端）

```powershell
cd CustomSoundpad_frontend
scons compiledb=yes          # compiledb=yes 同时生成 compile_commands.json（供 IDE 智能提示）
```

- 编译选项在 `build_profile.json` / `custom.py`（`custom.py` 已被忽略，可自行创建）。
- 产物输出到 `CustomSoundpad_frontend/project/bin/windows/*.dll`，该目录已在 `.gitignore` 中忽略，**不会提交**。
- 需要把构建产物也纳入版本控制时，删掉 `CustomSoundpad_frontend/.gitignore` 里的 `/project/bin/**` 两行。

### 2. APO 驱动与安装程序

用 Visual Studio 打开 `InjectAudioApo/InjectAudioApo.slnx`，编译 `Apo`（驱动 DLL）、`ApoTester`（测试程序）和 `Setup`（安装程序）。
开发期签名脚本：`InjectAudioApo/Sign-Dev.ps1`。

构建输出（`build/`、`x64/`、`.vs/`）已被 `InjectAudioApo/.gitignore` 忽略。

## godot-cpp 子模块：复原 / 切回 master

`CustomSoundpad_frontend/godot-cpp` 是 `https://github.com/godotengine/godot-cpp.git` 的子模块，
`.gitmodules` 中声明 **`branch = master`**，即默认跟踪上游 `master`。

### 常见问题

- 在子模块里 `git checkout` 过别的分支后，子模块停在 **detached HEAD**，`git status` 显示 `+`/`-` 前缀；
- 上游模板原本写的是 `branch = 4.3`，执行 `git submodule update --remote` 会被拽回 4.3；
- 编译报找不到 `gdextension/extension_api-*.json` 或 API 版本不匹配 —— 多半是 godot-cpp 版本与 Godot 编辑器不一致。

### 方案 A：子模块正常存在，只是切回 master 分支

```powershell
cd CustomSoundpad_frontend

# 看当前状态：行首字符 空格=正常，-=未初始化，+=HEAD 与索引不一致
git submodule status

# 1) 按 .gitmodules 的 branch 拉取最新（会 checkout 到 origin/master，此时是 detached HEAD）
git submodule update --remote godot-cpp

# 2) 如果想真正站在 master 分支上（便于直接 pull）
git -C godot-cpp fetch origin
git -C godot-cpp checkout master
git -C godot-cpp pull --ff-only origin master

# 3) 确认
git -C godot-cpp status -sb      # 期望：## master...origin/master
git submodule status             # 期望：空格 6cceaf6... godot-cpp (...)
```

### 方案 B：固定在某个提交（不跟 master 跑）

```powershell
cd CustomSoundpad_frontend
git -C godot-cpp fetch origin
git -C godot-cpp checkout <commit-sha>     # 或某个 tag，例如 godot-4.3-stable
git add godot-cpp
git commit -m "chore: pin godot-cpp to <commit/tag>"
```

### 方案 C：彻底重建子模块（目录损坏 / 想重新下载）

```powershell
cd CustomSoundpad_frontend

# 反初始化：会删除 godot-cpp/ 工作区内容和 .git/modules/godot-cpp
git submodule deinit -f godot-cpp

# 重新拉取（按索引中记录的提交检出）
git submodule update --init --recursive godot-cpp

# 需要跟到 master 最新，再执行方案 A 的第 1~2 步
git submodule update --remote godot-cpp
git -C godot-cpp checkout master
git -C godot-cpp pull --ff-only origin master
```

### 收尾：提交子模块指针

godot-cpp 版本变化后，**必须**回来提交指针，否则别人克隆到的还是旧版本：

```powershell
cd CustomSoundpad_frontend
git add .gitmodules godot-cpp
git commit -m "chore: godot-cpp 恢复到 master"
git push
```

然后切版本后要**重新编译** GDExtension（`scons`），并确保 Godot 编辑器版本与 godot-cpp 的 API 版本一致。

## 目录说明

```
customSoundPad/
├── README.md                     # 本文件
├── update.ps1                    # 一键提交 + 推送（三个仓库按序处理）
├── CustomSoundpad_frontend
└── InjectAudioApo/               # submodule → inject_audio_apo
    ├── Apo/                      # APO 驱动（InjectAudioApoDll / EFX）
    ├── ApoTester/                # 测试程序 + test.wav（46 MB，已提交）
    └── Setup/                    # 安装程序
```

## 已知体积较大的文件

- `InjectAudioApo/ApoTester/test.wav` 与 `CustomSoundpad_frontend/project/test.wav` 各约 **46 MB**，均为测试音频。
  若后续频繁改动这些文件，建议改用 [Git LFS](https://git-lfs.com/)：
  ```powershell
  git lfs install
  git lfs track "*.wav"
  git add .gitattributes
  ```
- `godot-cpp` 工作区约 915 MB，但只有指针进版本库，不占远端空间（克隆时重新下载）。
