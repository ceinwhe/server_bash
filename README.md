# 服务器初始用户配置

`ssh-user-bootstrap.sh` 适用于使用 systemd, OpenSSH 和 sudo 的 Linux 服务器. 请在有交互终端的 root 会话中运行:

```bash
curl -fsSL https://raw.githubusercontent.com/ceinwhe/server_bash/refs/heads/main/ssh-user-bootstrap.sh | bash
```
cn用户
```bash
curl -fsSL https://api.gitproxy.dev/raw.githubusercontent.com/ceinwhe/server_bash/refs/heads/main/ssh-user-bootstrap.sh | bash
```

脚本会检查服务器上 root 和 `sudo` 调用者家目录中的 `.ssh`，自动迁移 `authorized_keys`、`authorized_keys2` 中的有效公钥，并逐个询问是否将 `*.pub` 公钥授权给新用户。检测时会显示实际检查的路径及各文件新增的公钥数量；不会导入或复制私钥。

如果没有导入公钥，可以按提示输入服务器上公钥文件的绝对路径（支持带空格的路径，无需加引号），或直接回车跳过。脚本无法检测本地电脑上的 `.ssh`，也不会自动扫描其他用户的家目录。只有 `id_rsa`、`id_ed25519` 等私钥时，请在持有私钥的电脑上导出对应公钥，再将公钥放到服务器供脚本导入，不要上传私钥。
