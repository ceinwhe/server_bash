# 服务器初始用户配置

`ssh-user-bootstrap.sh` 适用于使用 systemd, OpenSSH 和 sudo 的 Linux 服务器. 请在有交互终端的 root 会话中运行:

```bash
curl -fsSL https://你的地址/ssh-user-bootstrap.sh | bash
```

也可以先把脚本放到服务器, 再运行 `bash ssh-user-bootstrap.sh`. 脚本通过终端询问新用户名, 用户密码和 sudo 是否免密, 不使用命令参数. 它从 root (以及通过 sudo 进入 root 时的原用户) 的 `authorized_keys` 检测并复制可用公钥, 只复制公钥, 不复制私钥.

新用户创建后, 脚本会提示你保持当前会话, 并在另一个终端验证新用户能够 SSH 登录和使用 sudo. 确认成功后, 它才会设置 `PermitRootLogin no`, 锁定 root 密码并重新加载 SSH; 若此前失败或取消, 会尝试回滚已做的修改. 通过管道运行时脚本不会保存到服务器磁盘; 通过文件运行且成功完成时会删除该脚本文件. 用户, sudo 规则和 SSH 配置属于预期的永久配置.
