# 光鸭

光鸭云盘与影视媒体库的 Flutter 客户端。

## 分支约定

- `dev`：日常开发分支，功能和修复先提交到这里。
- `main`：稳定发布分支，只通过发布脚本由 `dev` 快进合并。

## 发布

默认按十进制递增补丁版本和 Flutter build number，将 `dev` 合并到
`main`，创建版本标签，并原子推送两个分支及标签：

```bash
./release.sh
```

指定版本时可以省略或明确填写 build number：

```bash
./release.sh --version 1.2.3
./release.sh --version 1.2.3+45
```

无人值守发布使用 `--yes`，发布前预览完整计划使用 `--dry-run`。运行
`./release.sh --help` 可查看分支、远程仓库等完整选项。
