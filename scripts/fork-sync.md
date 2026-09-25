---
name: no-mistakes-fork-sync
description: 同步 onyx-space/no-mistakes fork 到上游 kunchenguid/no-mistakes，并从 fork 检出重新 build、装成运行时。当要更新 no-mistakes、同步 fork、升级本地 no-mistakes、或出现「no-mistakes --version 落后于上游」时用。**运行时 = fork 的本地构建**：`no-mistakes update` 装的是官方发布版，会把它换掉，不得用来更新运行时。
---

# no-mistakes Fork Sync

`onyx-space/no-mistakes` fork 的对上游同步 + 本地构建安装。可执行体是仓内脚本
[`scripts/fork-sync.sh`](fork-sync.sh)（与本文件同目录）；本文件是它的说明，也是
skill 本体。

## 安装本 skill（操作者动作）

共享 skill 目录不由会话写入，把本文件装进去是操作者的动作：

```sh
install -Dm644 ~/code/no-mistakes/scripts/fork-sync.md \
  ~/.agents/skills/no-mistakes-fork-sync/SKILL.md
```

装完后按名字即可被调用；脚本本身随 fork 走，不需要额外安装。

## 机制背景（为什么这么干）

- **运行时 = 本地构建**：端点的 `no-mistakes` 命令指向本机 fork 检出的 `make build`
  产物，经 `install -m 755` 装到 `~/.local/bin/no-mistakes`。所以「升级」=
  同步 fork + 重新 build + 换二进制，**不是** `no-mistakes update`。
- **`no-mistakes update` 会换掉它**：它从 GitHub 下载官方 release（当前会从
  `v1.72.0-12-g38bd649` 换到官方 `v1.79.0+`），也就是 fork 的本地血统被官方版顶掉。
  该命令不得用于更新运行时；跑过之后要用 `readlink -f "$(command -v no-mistakes)"`
  与 `no-mistakes --version` 复核。
- **先验证再换二进制**：脚本先 `make build`，再比对构建产物自报的版本与
  `git describe --tags --always --dirty`；两者一致才替换。替换前把旧二进制备份到
  `~/.cache/no-mistakes-backup/no-mistakes.bak-<旧版本>`，替换后任何一步失败都会自动
  回滚（**失败时留在盘上的仍是原来那个二进制**）。
- **不打断在飞管线**：daemon 与 CLI 不能跑不同构建（生命周期闸就是为此存在的）。
  脚本在替换二进制**之前**读 `~/.no-mistakes/state.sqlite` 的 `runs` 表，有未终态 run
  就拒绝并列出，除非显式 `--force`。替换成功后用 `no-mistakes daemon restart` 让 daemon
  吃上新构建；daemon 判据 = 进程启动时间晚于二进制 mtime。

## 用法

从任意目录都能跑（仓库按脚本自身位置解析）：

```sh
# 同步 + 重建 + 安装（默认对 main）
~/code/no-mistakes/scripts/fork-sync.sh

# 本端点：构建血统不是 main，是指定的那条分支
~/code/no-mistakes/scripts/fork-sync.sh --branch local/v1.72.0-docfix

# 只同步 + 构建，不动部署（替换二进制/重启 daemon 要队长批准时用这个）
~/code/no-mistakes/scripts/fork-sync.sh --branch local/v1.72.0-docfix --no-install

# 别的检出 / 别的二进制 / 别的上游
~/code/no-mistakes/scripts/fork-sync.sh --repo ~/code/no-mistakes --bin ~/.local/bin/no-mistakes
```

参数：`--repo`、`--branch`（默认 `main`）、`--bin`、`--upstream`、`--no-install`、`--force`、
`-h`。

## 它做了什么（顺序）

1. 工作区必须干净（不干净直接拒绝，不动别人的改动）；目标分支被检出时就在主检出里做，
   否则用一个临时 worktree —— **不会把主检出的分支切走**。
2. 缺则 `git remote add upstream https://github.com/kunchenguid/no-mistakes.git`，然后
   `git fetch --prune upstream`。
3. `git merge-tree --write-tree` 预检冲突，有 `CONFLICT` 就先报错退出（合并前不写任何东西）。
4. `git merge --no-edit upstream/main`；失败则 `merge --abort`。
5. 校验：`HEAD..upstream/main` 计数为 0，且 `upstream/main` 是 `HEAD` 的祖先，并列出
   `upstream/main..HEAD`（fork 自己的 commit，必须还在）。
6. `make build`，再校验 `bin/no-mistakes --version` 的版本号 == 该分支的
   `git describe --tags --always --dirty`。
7. 查在飞 run（`state.sqlite`）→ 备份旧二进制 → `install -m 755` → `cmp` 校验字节一致 →
   `no-mistakes daemon restart` → 校验运行中的 daemon 进程晚于新二进制。
8. 任何失败：回滚到备份（并尝试把 daemon 指回旧构建），退出非零。

幂等：对已同步的 fork 再跑一次，merge 无事可做、build 出同样字节、install 同样字节、
且**不重启 daemon**。

## 常见坑

- **`--branch` 用错**：本端点的构建血统是 `local/v1.72.0-docfix`（`origin/main` 落后它
  147 笔），同步/构建都用这条；`main` 只是 fork 的发布镜像线。
- **合并不动主检出**：脚本用临时 worktree 保护「主检出停在血统分支」这条要求；主检出上
  有未提交改动时脚本会直接拒绝。
- **`no-mistakes update` 顶掉本地构建**：这是本 skill 存在的原因；跑了就用
  `--version` 与 `readlink -f` 复核，并按上面的流程重新 build 装回。
- **有在飞 run 时替换二进制**：不要 `--force`；先等管线落定（`no-mistakes axi status`）。
- **daemon 起不来**：脚本会回滚二进制；回滚后再看 `~/.no-mistakes/logs/daemon-bootstrap.log`。
- **`make build` 报找不到 go**：脚本会把 `/usr/local/go/bin` 与 `~/go/bin` 补进 PATH，
  仍失败就是 Go 本体缺失。
