import Foundation

// askpass 模式:当本可执行文件被 ssh 作为 SSH_ASKPASS 程序调起时,
// 从 Keychain 取密码写到 stdout 后立即退出,绝不初始化 GUI。
Askpass.runIfRequested()

HelmApp.main()
