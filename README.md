# Helm

原生 macOS 服务器指挥中心:集中管理科研服务器(SLURM 集群 + 独立 GPU 机),
一键连接、实时监控、批量命令、文件传输、内嵌终端。

## 构建

```sh
brew install xcodegen        # 如未安装
xcodegen generate            # 从 project.yml 生成 Helm.xcodeproj
xcodebuild -project Helm.xcodeproj -scheme Helm build
xcodebuild -project Helm.xcodeproj -scheme Helm test
```

新增/删除源文件后需要重新 `xcodegen generate`。

## 架构铁律

- 连接层走系统 `/usr/bin/ssh` + ControlMaster(socket 在 `~/.helm/sockets`),
  完整继承 `~/.ssh/config`(ProxyJump、密钥、agent)
- **监控探测永远 `BatchMode` + 只复用 master,绝不触发新认证**(不会弹 2FA)
- 密码只存 macOS Keychain(service `app.helm.ssh`);SSH_ASKPASS 指向 Helm
  自身可执行文件(`main.swift` 拦截 `HELM_ASKPASS` 环境变量),同一代码身份免二次授权
- 所有远端探测命令以普通用户执行,全程无 sudo
- ssh config 可视化编辑走无损文档模型(注释/空行/Match/通配块逐字节保留),
  每次写入前备份到 `~/Library/Application Support/Helm/config-backups`(留最近 20 份),
  原子写 + `ssh -G` 校验,失败自动回滚;多别名共享块与通配块保持只读
- SwiftTerm 钉在 1.11.2:1.12+ 需要单独下载 Metal 工具链
  (`xcodebuild -downloadComponent MetalToolchain`)

## 说明

- 带 passphrase 的密钥:首次连接弹原生口令框,验证后由 ssh(`UseKeychain`)存入
  系统钥匙串,之后全程静默;Helm 自身不存储 passphrase
- 开发用 ad-hoc 签名,重建后首次读 Keychain 会重新弹授权;换正式证书可消除

## 许可证

[MIT](LICENSE)
