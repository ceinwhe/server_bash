#!/usr/bin/env bash
# Linux + systemd + OpenSSH. Run with Bash, never with sh.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage:
  sudo bash ssh-user-bootstrap.sh prepare USER [AUTHORIZED_KEYS_FILE]
  # Log in through SSH as USER, then run the printed finalize command.

Creates a NEW administrator with passwordless sudo and SSH public keys.
Default sources: root's authorized_keys, then the invoking sudo user's.
Private keys are never copied. Existing authorized_keys restrictions are kept.
Finalization locks root's password and disables ALL new root SSH logins.
EOF
}
[[ ${1:-} == --help || ${1:-} == -h ]] && { usage; exit 0; }
[[ $# -ge 2 && $# -le 3 ]] || { usage; exit 1; }
mode=$1 name=$2
[[ $mode == prepare || $mode == finalize ]] || die 'Unknown mode.'
[[ $name =~ ^[a-z_][a-z0-9_-]{0,30}$ && $name != root ]] || die 'Invalid new username.'
[[ $EUID -eq 0 ]] || die 'Run as root or through sudo.'
for cmd in sshd ssh-keygen useradd passwd getent sudo visudo python3 systemctl flock install chpasswd; do
    command -v "$cmd" >/dev/null || die "Missing dependency: $cmd"
done
exec 9>/run/ssh-user-bootstrap.lock
flock -n 9 || die 'Another bootstrap operation is running.'
config=/etc/ssh/sshd_config
[[ -f $config && ! -L $config ]] || die 'Expected a regular /etc/ssh/sshd_config.'
sshd -t
service_name=
for unit in ssh.service sshd.service; do
    if systemctl is-active --quiet "$unit"; then service_name=$unit; break; fi
done
[[ -n $service_name ]] || die 'No active systemd SSH service found.'
[[ $(systemctl show -p CanReload --value "$service_name") == yes ]] || die 'SSH service does not support reload.'
base=/var/lib/ssh-user-bootstrap
[[ ! -L $base ]] || die 'State directory must not be a symlink.'
install -d -o root -g root -m 700 "$base"
state=$base/$name
sudoers=/etc/sudoers.d/90-ssh-bootstrap-$name
work=$(mktemp -d /run/ssh-user-bootstrap.XXXXXXXX)
config_changed=0
password_changed=0
committed=0
cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    if (( ! committed && (config_changed || password_changed) )); then
        printf 'Finalization failed; restoring root access settings.\n' >&2
        if (( password_changed )); then
            { printf 'root:'; cat "$state/root-password.before"; } | chpasswd -e \
                || printf 'URGENT: root password rollback failed; use the existing sudo session.\n' >&2
        fi
        if (( config_changed )); then
            cp -a -- "$state/sshd_config.before" "$config" && sshd -t && systemctl reload "$service_name" \
                || printf 'URGENT: SSH rollback failed; use the existing sudo session.\n' >&2
        fi
    fi
    rm -rf -- "$work"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

effective() {
    local who=$1 address=127.0.0.1 server=127.0.0.1 port=22 unused
    if [[ -n ${SSH_CONNECTION:-} ]]; then
        read -r address unused server port <<< "$SSH_CONNECTION"
    fi
    sshd -T -C "user=$who,host=$address,addr=$address,laddr=$server,lport=$port"
}
check_user_config() {
    effective "$name" > "$work/effective"
    grep -qx 'pubkeyauthentication yes' "$work/effective" || die 'Public-key authentication is disabled for this user.'
    grep -qx 'usepam yes' "$work/effective" || die 'This script requires UsePAM yes for a password-locked new account.'
    python3 - "$work/effective" "$user_home" <<'PY'
import sys
settings = dict(line.rstrip('\n').split(' ', 1) for line in open(sys.argv[1]) if ' ' in line)
paths = settings.get('authorizedkeysfile', '').split()
home = sys.argv[2]
if not any(p in ('.ssh/authorized_keys', '%h/.ssh/authorized_keys', home + '/.ssh/authorized_keys') for p in paths):
    sys.exit('ERROR: sshd does not read this user\'s ~/.ssh/authorized_keys; adjust the custom configuration first.')
PY
}

if [[ $mode == prepare ]]; then
    getent passwd "$name" >/dev/null && die 'User already exists; refusing to overwrite an existing account.'
    [[ ! -e $state && ! -e $sudoers && ! -L $sudoers ]] || die 'Bootstrap state or sudo rule already exists.'
    [[ -d /etc/sudoers.d && ! -L /etc/sudoers.d ]] || die 'Expected /etc/sudoers.d.'
    visudo -c >/dev/null
    sources=()
    if [[ $# == 3 ]]; then
        [[ -f $3 && -r $3 ]] || die 'Specified public-key file is unreadable.'
        sources=("$3")
    else
        root_home=$(getent passwd root | cut -d: -f6)
        sources=("$root_home/.ssh/authorized_keys" "$root_home/.ssh/authorized_keys2")
        if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
            prior_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
            [[ -n $prior_home ]] && sources+=("$prior_home/.ssh/authorized_keys" "$prior_home/.ssh/authorized_keys2")
        fi
    fi
    found=0
    for source in "${sources[@]}"; do
        [[ -s $source && -r $source ]] || continue
        : > "$work/keys"
        count=0
        while IFS= read -r line || [[ -n $line ]]; do
            line=${line%$'\r'}
            [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
            [[ $line != *'PRIVATE KEY'* ]] || die 'Private-key input detected; only use authorized_keys or a public-key file.'
            printf '%s\n' "$line" > "$work/one-key"
            ssh-keygen -l -f "$work/one-key" >/dev/null 2>&1 \
                || die "Malformed public-key entry in $source; fix it before continuing."
            printf '%s\n' "$line" >> "$work/keys"
            count=$((count + 1))
        done < "$source"
        if (( count > 0 )); then found=1; break; fi
    done
    (( found )) || die 'No usable public-key entries found. Supply an authorized_keys file explicitly.'
    printf 'Selected source: %s (%s entries)\n' "$source" "$count"
    ssh-keygen -l -f "$work/keys"
    user_home=/home/$name
    [[ ! -e $user_home && ! -L $user_home ]] || die 'Home path already exists.'
    check_user_config
    install -d -o root -g root -m 700 "$state"
    # Keep a root-owned copy so the second phase has a stable path.
    install -o root -g root -m 700 -- "${BASH_SOURCE[0]}" "$state/bootstrap.sh"
    useradd --create-home --user-group --home-dir "$user_home" --shell /bin/bash "$name"
    passwd -l "$name" >/dev/null
    chmod 750 "$user_home"
    install -d -o "$name" -g "$name" -m 700 "$user_home/.ssh"
    install -o "$name" -g "$name" -m 600 "$work/keys" "$user_home/.ssh/authorized_keys"
    if command -v restorecon >/dev/null; then restorecon -RF "$user_home"; fi
    printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$name" > "$work/sudoers"
    visudo -cf "$work/sudoers" >/dev/null
    install -o root -g root -m 440 "$work/sudoers" "$sudoers"
    if ! visudo -c >/dev/null || ! sudo -u "$name" sudo -n /usr/bin/true; then
        rm -f -- "$sudoers"
        die 'sudo verification failed. New account retained; root access unchanged.'
    fi
    id -u "$name" > "$state/uid"
    touch "$state/prepared"
    cat <<EOF

PREPARED: $name now has SSH keys and passwordless sudo.
Root access has not yet changed. Keep this session open.

From a NEW terminal on your own computer, log in using your private key:
  ssh -o PreferredAuthentications=publickey -o PasswordAuthentication=no -o ControlMaster=no -o ControlPath=none $name@SERVER_IP
Add -i PRIVATE_KEY and/or -p PORT if required.

In that NEW SSH session, run:
  sudo -n env SSH_CONNECTION="\$SSH_CONNECTION" bash $state/bootstrap.sh finalize $name
EOF
    exit 0
fi

[[ $# == 2 ]] || die 'finalize does not accept a key-file argument.'
[[ -f $state/prepared && ! -L $state ]] || die 'Run prepare first.'
[[ ! -f $state/completed ]] || die 'Already completed; no changes made.'
[[ ${SUDO_USER:-} == "$name" && -n ${SSH_CONNECTION:-} ]] \
    || die 'Run finalize through sudo from the new user SSH session, passing SSH_CONNECTION as printed.'
[[ $(id -u "$name") == "$(cat "$state/uid")" ]] || die 'Account identity changed since preparation.'
sudo -u "$name" sudo -n /usr/bin/true || die 'New administrator cannot use passwordless sudo.'
user_home=$(getent passwd "$name" | cut -d: -f6)
check_user_config

# Follow Include directives and reject any conditional root-login override.
# Global settings are overridden by the new first line; Match rules can override
# globals, so checking only sshd -T for one address would not be sufficient.
python3 - "$config" <<'PY'
import glob, os, re, shlex, sys
def scan(path, conditional=False, stack=()):
    real = os.path.realpath(path)
    if real in stack or len(stack) > 32:
        sys.exit('ERROR: cyclic or excessive SSH Include nesting.')
    with open(path, encoding='utf-8') as f:
        for number, line in enumerate(f, 1):
            line = re.sub(r'^(\s*[A-Za-z]+)\s*=\s*', r'\1 ', line)
            parts = shlex.split(line, comments=True)
            if not parts:
                continue
            key = parts[0].lower()
            if key == 'match':
                conditional = True
            elif key == 'include':
                for pattern in parts[1:]:
                    if not os.path.isabs(pattern):
                        pattern = os.path.join('/etc/ssh', pattern)
                    for child in sorted(glob.glob(pattern)):
                        conditional = scan(child, conditional, stack + (real,))
            elif key == 'permitrootlogin' and conditional and parts[1:] != ['no']:
                sys.exit(f'ERROR: conditional PermitRootLogin override at {path}:{number}; resolve it first.')
    return conditional
scan(sys.argv[1])
PY

cp -a -- "$config" "$state/sshd_config.before"
awk -F: '$1 == "root" { print $2 }' /etc/shadow > "$state/root-password.before"
[[ -s $state/root-password.before ]] || die 'Cannot save root password state.'
cp -a -- "$config" "$work/sshd_config.next"
{ printf '# Managed by ssh-user-bootstrap\nPermitRootLogin no\n'; cat "$config"; } > "$work/sshd_config.next"
sshd -t -f "$work/sshd_config.next"
config_changed=1
cat "$work/sshd_config.next" > "$config"
sshd -t
effective root > "$work/root-effective"
grep -qx 'permitrootlogin no' "$work/root-effective" || die 'Root SSH prohibition did not take effect.'
check_user_config
systemctl reload "$service_name"
systemctl is-active --quiet "$service_name" || die 'SSH service is not active after reload.'
password_changed=1
passwd -l root >/dev/null
passwd -S root | awk '$2 == "L" { ok=1 } END { exit !ok }' || die 'Root password lock could not be verified.'
touch "$state/completed"
committed=1
printf 'DONE: root password is locked; all new root SSH logins are disabled.\n'
printf 'Administrator: %s; protected backup: %s\n' "$name" "$state"
printf 'Existing SSH sessions remain open. Keep the new administrator session until a second login succeeds.\n'
