#!/usr/bin/env bash
# 适用于使用 systemd 和 OpenSSH 的 Linux 服务器.
# 先完整读取函数, 再执行配置, 支持 curl | bash 等管道方式.
main() {
    set -Eeuo pipefail
    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    umask 077

    fail() { printf '错误:%s\n' "$*" >&2; exit 1; }
    say() { printf '%s\n' "$*" >&4; }
    ask() {
        printf '%s' "$1" >&4
        IFS= read -r REPLY <&3 || fail '无法从终端读取输入.'
    }
    ask_yes_no() {
        while :; do
            ask "$1 [y/n]:"
            case $REPLY in
                y|Y|yes|YES|是) return 0 ;;
                n|N|no|NO|否) return 1 ;;
            esac
            say '请输入 y 或 n.'
        done
    }
    cleanup() {
        local result=$?
        trap - EXIT INT TERM
        if (( result != 0 )); then
            if (( root_locked )); then
                { printf 'root:'; cat "$temporary/root-password"; } | chpasswd -e \
                    || printf '紧急:恢复 root 密码失败, 请保留当前会话并手动检查.\n' >&2
            fi
            if (( ssh_changed )); then
                cp -a -- "$temporary/sshd_config" "$sshd_config" \
                    && "$sshd" -t \
                    && systemctl reload "$ssh_service" \
                    || printf '紧急:恢复 SSH 配置失败, 请保留当前会话并手动检查.\n' >&2
            fi
            if (( sudo_created )); then rm -f -- "$sudo_file"; fi
            if (( user_created )); then
                userdel -r -- "$username" >/dev/null 2>&1 \
                    || printf '警告:自动删除新用户失败, 请手动检查 %s.\n' "$username" >&2
            fi
        fi
        if [[ -n ${temporary:-} && -d $temporary ]]; then rm -rf -- "$temporary"; fi
        # 管道运行没有源文件; 文件运行成功后删除源文件.
        if (( result == 0 )) && [[ -n ${script_file:-} ]]; then
            rm -f -- "$script_file" || printf '警告:未能删除脚本文件 %s.\n' "$script_file" >&2
        fi
        exit "$result"
    }

    [[ $# -eq 0 ]] || fail '本脚本不接受命令参数, 请按中文提示操作.'
    [[ $EUID -eq 0 ]] || fail '请以 root 身份运行, 例如 curl -fsSL 地址 | sudo bash.'
    [[ -r /dev/tty && -w /dev/tty ]] || fail '需要可交互的终端.'
    exec 3</dev/tty 4>/dev/tty
    for tool in useradd userdel getent chpasswd passwd ssh-keygen visudo sudo \
                install systemctl mktemp cp awk python3 grep readlink; do
        command -v "$tool" >/dev/null || fail "缺少所需命令:$tool"
    done
    sshd=$(command -v sshd) || fail '未找到 sshd.'
    sshd_config=/etc/ssh/sshd_config
    [[ -f $sshd_config && ! -L $sshd_config ]] || fail '未找到常规 SSH 配置文件 /etc/ssh/sshd_config.'
    "$sshd" -t || fail '现有 SSH 配置检查失败, 请先修复.'
    ssh_service=
    for service in ssh.service sshd.service; do
        if systemctl is-active --quiet "$service"; then ssh_service=$service; break; fi
    done
    [[ -n $ssh_service ]] || fail '没有运行中的 systemd SSH 服务.'
    [[ $(systemctl show -p CanReload --value "$ssh_service") == yes ]] \
        || fail 'SSH 服务不支持重新加载.'
    [[ -d /etc/sudoers.d && ! -L /etc/sudoers.d ]] || fail '找不到常规的 /etc/sudoers.d 目录.'
    visudo -c >/dev/null || fail '现有 sudo 配置检查失败, 请先修复.'

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

    say '将创建普通用户, 设置密码和 sudo 权限, 然后禁止 root 密码及密钥登录.'
    say '第一步:填写全部配置. 此阶段只检查环境和准备临时文件, 不修改用户或系统配置.'
    while :; do
        ask '请输入新用户名:'
        username=$REPLY
        [[ $username =~ ^[a-z_][a-z0-9_-]{0,30}$ && $username != root ]] || {
            say '用户名只能以小写字母或下划线开头, 后续使用小写字母, 数字, _ 或 -, 最长 31 字符.'
            continue
        }
        getent passwd "$username" >/dev/null && { say '该用户已存在, 请换一个用户名.'; continue; }
        [[ ! -e /home/$username && ! -L /home/$username ]] || {
            say '同名家目录已存在, 请换一个用户名.'; continue;
        }
        break
    done
    while :; do
        printf '请输入新用户密码:' >&4
        IFS= read -r -s password <&3 || fail '无法读取密码.'
        printf '\n请再次输入密码:' >&4
        IFS= read -r -s confirmation <&3 || fail '无法读取密码确认.'
        printf '\n' >&4
        [[ -n $password ]] || { say '密码不能为空.'; continue; }
        [[ $password == "$confirmation" ]] && break
        say '两次密码不一致, 请重新输入.'
    done
    unset confirmation
    passwordless=0
    if ask_yes_no '是否允许该用户 sudo 免密'; then passwordless=1; fi

    temporary=$(mktemp -d /run/ssh-user-bootstrap.XXXXXXXX)
    user_created=0 sudo_created=0 ssh_changed=0 root_locked=0
    sudo_file=/etc/sudoers.d/99-ssh-user-bootstrap-$username
    [[ ! -e $sudo_file && ! -L $sudo_file ]] || fail '同名 sudo 规则已经存在.'
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    # 自动迁移已授权公钥; 独立公钥文件需要确认后才授权给新用户.
    : > "$temporary/keys"
    key_count=0
    import_public_keys() {
        local source=$1 line before=$key_count
        [[ -f $source && -r $source ]] || { say "无法读取公钥文件:$source"; return 0; }
        if grep -q -- '-----BEGIN .*PRIVATE KEY-----' "$source"; then
            say "跳过私钥文件:$source (请提供 .pub 公钥或 authorized_keys)"
            return 0
        fi
        while IFS= read -r line || [[ -n $line ]]; do
            line=${line%$'\r'}
            [[ $line =~ ^[[:space:]]*$ || $line =~ ^[[:space:]]*# ]] && continue
            printf '%s\n' "$line" > "$temporary/one-key"
            if ! ssh-keygen -l -f "$temporary/one-key" >/dev/null 2>&1; then
                say "跳过无效公钥:$source"
                continue
            fi
            if ! grep -Fqx -- "$line" "$temporary/keys"; then
                printf '%s\n' "$line" >> "$temporary/keys"
                key_count=$((key_count + 1))
            fi
        done < "$source"
        say "从 $source 新增 $((key_count - before)) 条授权公钥."
    }
    root_home=$(getent passwd root | awk -F: '{print $6}')
    [[ -n $root_home ]] || fail '无法确定 root 的家目录.'
    key_homes=("$root_home")
    if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
        caller_home=$(getent passwd "$SUDO_USER" | awk -F: '{print $6}')
        if [[ -n $caller_home && $caller_home != "$root_home" ]]; then
            key_homes+=("$caller_home")
        fi
    fi
    for key_home in "${key_homes[@]}"; do
        say "检查 SSH 公钥目录:$key_home/.ssh"
        if [[ ! -d $key_home/.ssh ]]; then
            say '目录不存在.'
            continue
        fi
        found_key_file=0
        for source in "$key_home/.ssh/authorized_keys" "$key_home/.ssh/authorized_keys2"; do
            [[ -f $source ]] || continue
            found_key_file=1
            import_public_keys "$source"
        done
        for source in "$key_home/.ssh/"*.pub; do
            [[ -f $source ]] || continue
            found_key_file=1
            if ask_yes_no "发现公钥文件 $source, 是否授权对应密钥登录新用户"; then
                import_public_keys "$source"
            fi
        done
        if (( ! found_key_file )); then
            say '未找到 authorized_keys、authorized_keys2 或 *.pub; 私钥不会被导入.'
        fi
    done
    if (( key_count == 0 )); then
        say '未导入公钥. 这里只能检测服务器上的文件, 无法读取本地电脑的 .ssh.'
        while :; do
            ask '请输入服务器上公钥或 authorized_keys 的绝对路径 (回车跳过):'
            [[ -n $REPLY ]] || break
            [[ $REPLY == /* ]] || { say '请输入绝对路径.'; continue; }
            import_public_keys "$REPLY"
            (( key_count == 0 )) || break
        done
    fi
    say "检测到 $key_count 条可用的 SSH 授权公钥."

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
        || fail '新用户没有可用的 SSH 密钥或密码登录方式, 已停止以免锁在服务器外.'
    grep -qx 'authenticationmethods any' "$temporary/user-ssh" \
        || fail 'SSH 设置了额外的多重认证要求, 请先手动处理.'

    # Match 可以覆盖全局 PermitRootLogin; 扫描 Include, 拒绝显式重新开放 root 的规则.
    python3 - "$sshd_config" <<'PY' || fail '发现可能覆盖 root 登录限制的 SSH 配置, 请先手动处理.'
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
    say '配置已填写完毕, 请核对:'
    say "  新用户名: $username"
    say "  家目录: /home/$username"
    say '  登录密码: 已填写 (不显示明文)'
    if (( passwordless )); then sudo_text=是; else sudo_text=否; fi
    say "  sudo 免密: $sudo_text"
    say "  待导入授权公钥: $key_count 条"
    say '  root 登录: 在新用户登录验证成功后禁用密码及密钥登录, 并锁定 root 密码'
    say '执行后还需在另一个终端验证新用户登录及 sudo, 再返回此处确认验证结果.'
    ask_yes_no '是否按以上配置开始执行' || fail '已取消, 未修改用户及系统配置.'

    say '第二步:按确认的配置创建用户并设置权限.'
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
    visudo -c >/dev/null || fail 'sudo 配置验证失败.'
    if (( passwordless )); then
        sudo -u "$username" sudo -n /usr/bin/true || fail 'sudo 免密验证失败.'
    else
        if sudo -u "$username" sudo -n /usr/bin/true >/dev/null 2>&1; then
            fail '其他 sudo 规则仍允许免密, 请先检查现有规则.'
        fi
    fi

    say '第三步:验证新用户登录, 验证成功后执行 root 登录限制.'
    say "新用户 $username 已配置好. 请保持此终端不关闭."
    say "请在另一个终端运行 ssh $username@服务器地址, 并确认能登录及使用 sudo."
    ask_yes_no '新终端是否已成功验证, 继续禁用 root 登录' \
        || fail '已取消; 新建用户和 sudo 规则将回滚, root 登录保持原状.'

    cp -a -- "$sshd_config" "$temporary/sshd_config"
    awk -F: '$1 == "root" { print $2 }' /etc/shadow > "$temporary/root-password"
    [[ -s $temporary/root-password ]] || fail '无法保存当前 root 密码状态.'
    { printf '# 由 ssh-user-bootstrap 设置: 禁止 root 使用密码及密钥登录\nPermitRootLogin no\n'; cat "$sshd_config"; } \
        > "$temporary/sshd-next"
    "$sshd" -t -f "$temporary/sshd-next" || fail '新 SSH 配置验证失败.'
    ssh_changed=1
    cat "$temporary/sshd-next" > "$sshd_config"
    "$sshd" -t || fail '写入后的 SSH 配置验证失败.'
    "$sshd" -T -C "user=root,host=$client_address,addr=$client_address,laddr=$server_address,lport=$server_port" > "$temporary/root-ssh"
    grep -qx 'permitrootlogin no' "$temporary/root-ssh" || fail 'root SSH 禁令未生效.'
    "$sshd" -T -C "$ssh_context" > "$temporary/user-ssh-after"
    if (( key_usable )); then
        grep -qx 'pubkeyauthentication yes' "$temporary/user-ssh-after" || fail '新用户密钥认证意外失效.'
    fi
    if (( password_usable )); then
        grep -qx 'passwordauthentication yes' "$temporary/user-ssh-after" || fail '新用户密码认证意外失效.'
    fi
    systemctl reload "$ssh_service"
    systemctl is-active --quiet "$ssh_service" || fail 'SSH 服务重新加载后未运行.'
    passwd -l root >/dev/null || fail '锁定 root 密码失败.'
    root_locked=1
    passwd -S root | awk '$2 ~ /^L/ { found=1 } END { exit !found }' || fail 'root 密码锁定验证失败.'

    say "完成: 普通用户 $username 已创建, 并设置了密码."
    if (( passwordless )); then sudo_text=是; else sudo_text=否; fi
    say "已复制 $key_count 条 SSH 授权公钥; sudo 免密: $sudo_text."
    say 'root 密码已锁定, root 的 SSH 密码和密钥登录均已禁用.'
    say "请保留当前会话, 并在新终端验证: ssh $username@服务器地址"
    if [[ -n $script_file ]]; then say '本地脚本文件将在退出时删除.'; fi
}

main "$@" </dev/null
