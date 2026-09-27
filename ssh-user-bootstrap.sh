#!/usr/bin/env bash
# 适用于使用 systemd 和 OpenSSH 的 Linux 服务器.
# 先完整读取函数, 再执行配置, 支持 curl | bash 等管道方式.
main() {
    set -Eeuo pipefail
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    umask 077

    fail() { printf '[错误] %s\n' "$*" >&2; exit 1; }
    cancel() { printf '[取消] %s\n' "$*" >&2; exit 1; }
    say() { printf '[信息] %s\n' "$*" >&4; }
    warn() { printf '[警告] %s\n' "$*" >&4; }
    success() { printf '[完成] %s\n' "$*" >&4; }
    stage() { printf '\n-- %s --\n' "$*" >&4; }
    detail() { printf '  %s: %s\n' "$1" "$2" >&4; }
    ask() {
        printf '[输入] %s' "$1" >&4
        IFS= read -r REPLY <&3 || fail '无法读取终端输入, 操作已中止.'
    }
    ask_yes_no() {
        while :; do
            ask "$1 [y/n]: "
            case $REPLY in
                y|Y|yes|YES|是) return 0 ;;
                n|N|no|NO|否) return 1 ;;
            esac
            warn '输入无效.请输入 y(是)或 n(否).'
        done
    }
    cleanup() {
        local result=$?
        trap - EXIT INT TERM
        if (( result != 0 )); then
            if (( root_locked )); then
                { printf 'root:'; cat "$temporary/root-password"; } | chpasswd -e \
                    || printf '[紧急] root 密码恢复失败.请保留当前会话并手动恢复.\n' >&2
            fi
            if (( ssh_changed )); then
                cp -a -- "$temporary/sshd_config" "$sshd_config" \
                    && "$sshd" -t \
                    && systemctl reload "$ssh_service" \
                    || printf '[紧急] SSH 配置恢复失败.请保留当前会话并手动恢复.\n' >&2
            fi
            if (( sudo_created )); then rm -f -- "$sudo_file"; fi
            if (( user_created )); then
                userdel -r -- "$username" >/dev/null 2>&1 \
                    || printf '[警告] 回滚时未能删除用户 %s, 请手动检查.\n' "$username" >&2
            fi
        fi
        if [[ -n ${temporary:-} && -d $temporary ]]; then rm -rf -- "$temporary"; fi
        # 管道运行没有源文件; 文件运行成功后删除源文件.
        if (( result == 0 )) && [[ -n ${script_file:-} ]]; then
            rm -f -- "$script_file" || printf '[警告] 未能删除脚本文件: %s\n' "$script_file" >&2
        fi
        exit "$result"
    }

    [[ $# -eq 0 ]] || fail '本脚本不接受命令行参数, 请按照交互提示配置.'
    [[ $EUID -eq 0 ]] || fail '权限不足, 请以 root 身份运行或使用 sudo bash.'
    [[ -r /dev/tty && -w /dev/tty ]] || fail '无法访问交互终端, 请在终端会话中运行.'
    exec 3</dev/tty 4>/dev/tty
    stage 'SSH 用户初始化'
    say '配置普通用户, SSH 公钥及 sudo 权限, 并在登录验证通过后限制 root 登录.'
    stage '1/5 环境检查'
    for tool in useradd userdel getent chpasswd passwd ssh-keygen visudo sudo \
                install systemctl mktemp cp awk python3 grep readlink; do
        command -v "$tool" >/dev/null || fail "缺少依赖命令: $tool.请安装后重试."
    done
    sshd=$(command -v sshd) || fail '未找到 sshd, 请安装 OpenSSH Server.'
    sshd_config=/etc/ssh/sshd_config
    [[ -f $sshd_config && ! -L $sshd_config ]] || fail '/etc/ssh/sshd_config 必须存在且为非符号链接的普通文件.'
    "$sshd" -t || fail '现有 SSH 配置校验失败, 请根据上述诊断修复后重试.'
    ssh_service=
    for service in ssh.service sshd.service; do
        if systemctl is-active --quiet "$service"; then ssh_service=$service; break; fi
    done
    [[ -n $ssh_service ]] || fail '未检测到运行中的 ssh.service 或 sshd.service.'
    [[ $(systemctl show -p CanReload --value "$ssh_service") == yes ]] \
        || fail '当前 SSH 服务不支持 reload, 无法应用配置.'
    [[ -d /etc/sudoers.d && ! -L /etc/sudoers.d ]] || fail '/etc/sudoers.d 必须存在且不能为符号链接.'
    visudo -c >/dev/null || fail '现有 sudo 配置校验失败, 请修复后重试.'
    success "环境检查通过.SSH 服务: $ssh_service"

    script_file=
    bash_file=$(readlink -f -- "$BASH")
    case ${BASH_SOURCE[0]} in
        /dev/fd/*|/proc/*/fd/*|-) ;;
        *)
            if [[ -f ${BASH_SOURCE[0]} && ! -L ${BASH_SOURCE[0]} ]]; then
                source_file=$(readlink -f -- "${BASH_SOURCE[0]}")
                if [[ $source_file != "$bash_file" ]]; then script_file=$source_file; fi
            fi
            ;;
    esac

    stage '2/5 配置录入'
    say '本阶段仅收集配置, 执行检查并准备临时文件; 确认执行前不会修改用户或系统配置.'
    while :; do
        ask '新用户名: '
        username=$REPLY
        [[ $username =~ ^[a-z_][a-z0-9_-]{0,30}$ && $username != root ]] || {
            warn '用户名须以小写字母或下划线开头, 仅允许小写字母, 数字, 下划线和连字符, 最长 31 个字符; 不能使用 root.'
            continue
        }
        getent passwd "$username" >/dev/null && { warn "用户已存在: $username.请使用其他用户名."; continue; }
        [[ ! -e /home/$username && ! -L /home/$username ]] || {
            warn "家目录已存在: /home/$username.请使用其他用户名."; continue;
        }
        break
    done
    while :; do
        printf '[输入] 登录密码(输入不回显): ' >&4
        IFS= read -r -s password <&3 || fail '无法读取登录密码, 操作已中止.'
        printf '\n[输入] 再次输入密码: ' >&4
        IFS= read -r -s confirmation <&3 || fail '无法读取密码确认输入, 操作已中止.'
        printf '\n' >&4
        [[ -n $password ]] || { warn '密码不能为空, 请重新输入.'; continue; }
        [[ $password == "$confirmation" ]] && break
        warn '两次输入的密码不一致, 请重新输入.'
    done
    unset confirmation
    passwordless=0
    if ask_yes_no '是否启用 sudo 免密执行'; then passwordless=1; fi

    temporary=$(mktemp -d /run/ssh-user-bootstrap.XXXXXXXX)
    user_created=0 sudo_created=0 ssh_changed=0 root_locked=0
    sudo_file=/etc/sudoers.d/99-ssh-user-bootstrap-$username
    [[ ! -e $sudo_file && ! -L $sudo_file ]] || fail "sudo 规则文件已存在: $sudo_file.请检查现有配置."
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    # 自动迁移已授权公钥; 独立公钥文件需要确认后才授权给新用户.
    : > "$temporary/keys"
    key_count=0
    import_public_keys() {
        local source=$1 confirm=${2:-0} line before=$key_count
        local -a public_lines=()
        # ssh-keygen 也接受 known_hosts; 先检查授权公钥的行格式, 避免误导入主机密钥.
        local flag='(cert-authority|restrict|no-agent-forwarding|no-port-forwarding|no-pty|no-user-rc|no-X11-forwarding|agent-forwarding|port-forwarding|pty|user-rc|X11-forwarding|no-touch-required|verify-required)'
        local value='(command|environment|expiry-time|from|permitlisten|permitopen|principals|tunnel)=("([^"\\]|\\.)*"|[^[:space:],"]+)'
        local option="($flag|$value)"
        local public_pattern="^[[:space:]]*($option(,$option)*[[:space:]]+)?(ssh-|ecdsa-|sk-)[^[:space:]]+[[:space:]]+"
        [[ -f $source && -r $source ]] || { warn "公钥文件不存在或不可读: $source"; return 0; }
        if grep -q -- '-----BEGIN .*PRIVATE KEY-----' "$source"; then
            say "跳过私钥文件: $source.仅接受公钥, 文件名及后缀不限."
            return 0
        fi
        while IFS= read -r line || [[ -n $line ]]; do
            line=${line%$'\r'}
            [[ $line =~ ^[[:space:]]*$ || $line =~ ^[[:space:]]*# ]] && continue
            [[ $line =~ $public_pattern ]] || continue
            printf '%s\n' "$line" > "$temporary/one-key"
            if ! ssh-keygen -l -f "$temporary/one-key" >/dev/null 2>&1; then
                warn "公钥校验失败, 已跳过该条记录.来源: $source"
                continue
            fi
            public_lines+=("$line")
        done < "$source"
        if (( ${#public_lines[@]} == 0 )); then
            say "已跳过不含有效授权公钥的文件: $source"
            return 0
        fi
        if (( confirm )); then
            say "识别到公钥文件: $source(${#public_lines[@]} 条有效记录)"
            ask_yes_no '是否将该文件中的公钥加入新用户授权列表' || return 0
        fi
        for line in "${public_lines[@]}"; do
            if ! grep -Fqx -- "$line" "$temporary/keys"; then
                printf '%s\n' "$line" >> "$temporary/keys"
                key_count=$((key_count + 1))
            fi
        done
        say "待导入列表新增 $((key_count - before)) 条公钥, 重复记录已排除.来源: $source"
    }
    root_home=$(getent passwd root | awk -F: '{print $6}')
    [[ -n $root_home ]] || fail '无法从用户数据库获取 root 家目录.'
    key_homes=("$root_home")
    if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
        caller_home=$(getent passwd "$SUDO_USER" | awk -F: '{print $6}')
        if [[ -n $caller_home && $caller_home != "$root_home" ]]; then
            key_homes+=("$caller_home")
        fi
    fi
    for key_home in "${key_homes[@]}"; do
        say "正在扫描公钥目录: $key_home/.ssh"
        if [[ ! -d $key_home/.ssh ]]; then
            say '目录不存在, 已跳过.'
            continue
        fi
        found_key_file=0
        for source in "$key_home/.ssh/authorized_keys" "$key_home/.ssh/authorized_keys2"; do
            [[ -f $source ]] || continue
            found_key_file=1
            import_public_keys "$source"
        done
        # 包括无后缀文件和隐藏文件; 不递归扫描子目录.
        for source in "$key_home/.ssh/"* "$key_home/.ssh/".[!.]* "$key_home/.ssh/"..?*; do
            [[ -f $source ]] || continue
            case ${source##*/} in authorized_keys|authorized_keys2) continue ;; esac
            found_key_file=1
            import_public_keys "$source" 1
        done
        if (( ! found_key_file )); then
            say '目录中没有可检查的普通文件.'
        fi
    done
    if (( key_count == 0 )); then
        warn '待导入公钥列表为空.仅支持读取服务器上的文件, 无法访问本地电脑的 .ssh 目录.'
        while :; do
            ask '服务器上的公钥文件绝对路径(回车跳过): '
            [[ -n $REPLY ]] || break
            [[ $REPLY == /* ]] || { warn '路径格式无效, 请输入以 / 开头的绝对路径.'; continue; }
            import_public_keys "$REPLY"
            (( key_count == 0 )) || break
        done
    fi
    say "公钥检查完成: $key_count 条记录待导入."

    # 修改 root 登录策略前, 确认新用户至少有一种 SSH 登录方式.
    # 当前 SSH 客户端的地址可让 Match Address 的检查更接近实际登录.
    client_address=127.0.0.1
    server_address=127.0.0.1
    server_port=22
    if [[ -n ${SSH_CONNECTION:-} ]]; then
        read -r client_address _ server_address server_port <<< "$SSH_CONNECTION"
    fi
    ssh_context="user=$username,host=$client_address,addr=$client_address,laddr=$server_address,lport=$server_port"
    "$sshd" -T -C "$ssh_context" > "$temporary/user-ssh"
    key_usable=0 password_usable=0
    if (( key_count > 0 )) && grep -qx 'pubkeyauthentication yes' "$temporary/user-ssh" \
        && python3 - "$temporary/user-ssh" "$username" <<'PY'
import sys
settings = dict(line.rstrip('\n').split(' ', 1) for line in open(sys.argv[1]) if ' ' in line)
home = '/home/' + sys.argv[2]
allowed = {'.ssh/authorized_keys', '%h/.ssh/authorized_keys', home + '/.ssh/authorized_keys'}
sys.exit(not any(path in allowed for path in settings.get('authorizedkeysfile', '').split()))
PY
    then key_usable=1; fi
    if grep -qx 'passwordauthentication yes' "$temporary/user-ssh"; then password_usable=1; fi
    (( key_usable || password_usable )) \
        || fail '未确认新用户具有可用的 SSH 公钥或密码登录方式, 已中止配置.'
    grep -qx 'authenticationmethods any' "$temporary/user-ssh" \
        || fail 'SSH 配置包含额外认证要求, 请先检查 AuthenticationMethods 设置.'

    # Match 可以覆盖全局 PermitRootLogin; 扫描 Include, 拒绝显式重新开放 root 的规则.
    python3 - "$sshd_config" <<'PY' || fail 'SSH 配置扫描未通过, 请检查 Include 文件及 Match 中的 PermitRootLogin 规则.'
import glob, os, re, shlex, sys
def scan(path, conditional=False, stack=()):
    real = os.path.realpath(path)
    if real in stack or len(stack) > 32:
        sys.exit(1)
    with open(path, encoding='utf-8') as source:
        for line in source:
            line = re.sub(r'^(\s*[A-Za-z]+)\s*=\s*', r'\1 ', line)
            parts = shlex.split(line, comments=True)
            if not parts:
                continue
            option = parts[0].lower()
            if option == 'match':
                conditional = True
            elif option == 'include':
                for pattern in parts[1:]:
                    if not os.path.isabs(pattern):
                        pattern = os.path.join('/etc/ssh', pattern)
                    for child in sorted(glob.glob(pattern)):
                        conditional = scan(child, conditional, stack + (real,))
            elif option == 'permitrootlogin' and conditional and [p.lower() for p in parts[1:]] != ['no']:
                sys.exit(1)
    return conditional
scan(sys.argv[1])
PY

    # 先准备并验证 sudo 规则, 配置收集完毕后再统一执行.
    if (( passwordless )); then
        printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$username" > "$temporary/sudoers"
    else
        printf '%s ALL=(ALL:ALL) ALL\n' "$username" > "$temporary/sudoers"
    fi
    visudo -cf "$temporary/sudoers" >/dev/null

    # 执行确认:所有配置输入及预检查必须在此之前完成.
    stage '3/5 配置确认'
    detail '用户名' "$username"
    detail '家目录' "/home/$username"
    detail '登录密码' '已填写, 不显示明文'
    if (( passwordless )); then sudo_text=启用; else sudo_text=禁用; fi
    detail 'sudo 免密' "$sudo_text"
    detail '待导入公钥' "$key_count 条"
    detail 'root 登录策略' '新用户验证通过后, 禁用 root SSH 登录并锁定 root 密码'
    say '执行后需在独立终端验证新用户登录及 sudo 权限, 再返回本终端确认.'
    ask_yes_no '确认以上配置并开始执行' || cancel '操作已取消, 未修改用户及系统配置.'

    stage '4/5 应用配置'
    say "正在创建用户 $username 并配置密码, SSH 公钥及 sudo 权限."
    useradd --create-home --user-group --home-dir "/home/$username" --shell /bin/bash "$username"
    user_created=1
    printf '%s:%s\n' "$username" "$password" | chpasswd
    unset password
    chmod 750 -- "/home/$username"
    if (( key_count > 0 )); then
        install -d -o "$username" -g "$username" -m 700 "/home/$username/.ssh"
        install -o "$username" -g "$username" -m 600 "$temporary/keys" "/home/$username/.ssh/authorized_keys"
        if command -v restorecon >/dev/null; then restorecon -RF "/home/$username"; fi
    fi
    install -o root -g root -m 440 "$temporary/sudoers" "$sudo_file"
    sudo_created=1
    visudo -c >/dev/null || fail '写入后的 sudo 配置校验失败.'
    if (( passwordless )); then
        sudo -u "$username" sudo -n /usr/bin/true || fail 'sudo 免密执行验证失败.'
    else
        if sudo -u "$username" sudo -n /usr/bin/true >/dev/null 2>&1; then
            fail '现有 sudo 规则仍允许免密执行, 与所选配置不符.请检查规则.'
        fi
    fi

    success "用户 $username 已配置完成, sudo 权限检查通过."
    stage '5/5 登录验证与 root 访问限制'
    say '请保持当前会话, 在独立终端登录新用户并验证 sudo 权限.'
    detail '登录命令' "ssh $username@服务器地址"
    ask_yes_no '是否已验证登录及 sudo 权限, 并继续禁用 root 登录' \
        || cancel '验证未确认, 将回滚新建用户及 sudo 规则; root 登录配置未修改.'
    say '正在应用 root 登录限制并重新加载 SSH 服务.'

    cp -a -- "$sshd_config" "$temporary/sshd_config"
    awk -F: '$1 == "root" { print $2 }' /etc/shadow > "$temporary/root-password"
    [[ -s $temporary/root-password ]] || fail '无法备份 root 密码状态, 已中止配置.'
    { printf '# 由 ssh-user-bootstrap 设置: 禁止 root 使用密码及密钥登录\nPermitRootLogin no\n'; cat "$sshd_config"; } \
        > "$temporary/sshd-next"
    "$sshd" -t -f "$temporary/sshd-next" || fail '待应用的 SSH 配置校验失败.'
    ssh_changed=1
    cat "$temporary/sshd-next" > "$sshd_config"
    "$sshd" -t || fail '写入后的 SSH 配置校验失败.'
    "$sshd" -T -C "user=root,host=$client_address,addr=$client_address,laddr=$server_address,lport=$server_port" > "$temporary/root-ssh"
    grep -qx 'permitrootlogin no' "$temporary/root-ssh" || fail 'root SSH 登录限制未通过有效配置检查.'
    "$sshd" -T -C "$ssh_context" > "$temporary/user-ssh-after"
    if (( key_usable )); then
        grep -qx 'pubkeyauthentication yes' "$temporary/user-ssh-after" || fail '配置变更后, 新用户的 SSH 公钥认证未保持启用.'
    fi
    if (( password_usable )); then
        grep -qx 'passwordauthentication yes' "$temporary/user-ssh-after" || fail '配置变更后, 新用户的 SSH 密码认证未保持启用.'
    fi
    systemctl reload "$ssh_service"
    systemctl is-active --quiet "$ssh_service" || fail 'SSH 服务重新加载后未处于运行状态.'
    passwd -l root >/dev/null || fail 'root 密码锁定操作失败.'
    root_locked=1
    passwd -S root | awk '$2 ~ /^L/ { found=1 } END { exit !found }' || fail 'root 密码锁定状态验证失败.'

    stage '执行结果'
    success '用户初始化及 SSH 访问限制已完成.'
    detail '用户名' "$username"
    detail '已导入公钥' "$key_count 条"
    detail 'sudo 免密' "$sudo_text"
    detail 'root SSH 登录' '已禁用'
    detail 'root 密码' '已锁定'
    say '请保留当前会话, 并在独立终端再次确认登录正常.'
    detail '登录命令' "ssh $username@服务器地址"
    if [[ -n $script_file ]]; then say '退出时将自动删除本地脚本文件.'; fi
}

main "$@" </dev/null
