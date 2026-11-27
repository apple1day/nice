#!/bin/bash
# The release bundle places this script beside the payload, recovery and apksigner.
set -euo pipefail
umask 077
bundle=$(cd -- "$(dirname -- "$0")" && pwd -P)
payload="$bundle/payload.apk"
recovery="$bundle/NiceVideos-Mobile-Recovery.tar.age"
signer="$bundle/apksigner.jar"
output="$bundle/NiceVideos-Android-1.3.11-Update.apk"
expected=94b219553d6b9f07108b25d9be09764e94445e9f140200635e33ba7626f6a21b

die() { printf '%s\n' "$*" >&2; exit 1; }
[[ $# -le 1 ]] || die '可选参数为一个 SSH 私钥文件路径。'
for file in "$payload" "$recovery" "$signer"; do
    [[ -s "$file" ]] || die "请先完整解压更新包，缺少文件 $(basename "$file")。"
done
command -v java >/dev/null 2>&1 && java -version >/dev/null 2>&1 ||
    die '请先安装 Java 17 或更高版本，再双击此文件。使用 Homebrew 可运行 brew install --cask temurin@17。'
work=$(mktemp -d "${TMPDIR:-/tmp}/nice-mobile.XXXXXXXX")
stage=''
cleanup() {
    rm -rf -- "$work"
    if [[ -n "$stage" ]]; then rm -rf -- "$stage"; fi
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

verify_owner() {
    local digest
    java -jar "$signer" verify --verbose --print-certs "$1" > "$work/verify.log" || return 1
    digest=$(awk '/^Signer #[0-9]+ certificate SHA-256 digest: /{print $NF}' "$work/verify.log")
    [[ "$digest" == "$expected" ]]
}
# Compare the archive contents because signing can change ZIP metadata and add signatures.
same_payload() {
    local file entry
    for file in "$1" "$2"; do
        unzip -Z1 "$file" | LC_ALL=C awk '!/^META-INF\/([^/]+\.(SF|RSA|DSA|EC)|MANIFEST\.MF)$/' |
            LC_ALL=C sort > "$work/entries"
        if [[ "$file" == "$1" ]]; then
            cp "$work/entries" "$work/original-entries"
        else
            cmp -s "$work/entries" "$work/original-entries" || return 1
        fi
        while IFS= read -r entry; do
            # The app build emits plain resource paths without wildcard characters.
            [[ "$entry" != *'['* && "$entry" != *'*'* && "$entry" != *'?'* ]] || return 1
            unzip -p "$file" "$entry" | shasum -a 256 || return 1
        done < "$work/entries" > "$work/hashes"
        if [[ "$file" == "$1" ]]; then
            cp "$work/hashes" "$work/original-hashes"
        else
            cmp -s "$work/hashes" "$work/original-hashes" || return 1
        fi
    done
}
if [[ -e "$output" || -L "$output" ]]; then
    if [[ ! -L "$output" && -f "$output" ]] && verify_owner "$output" && same_payload "$payload" "$output"; then
        printf '已有覆盖更新包，签名和应用内容都已核对。\n%s\n' "$output"
        exit 0
    fi
    die "已有不同的同名文件，请先为它改名，再重新运行。原文件位于 $output"
fi

case "$(uname -m)" in
    arm64|aarch64) age="$bundle/tools/age-arm64" ;;
    x86_64|amd64)  age="$bundle/tools/age-amd64" ;;
    *)             age='' ;;
esac
if [[ "$(uname -s)" != Darwin || ! -x "$age" ]]; then
    age=$(command -v age) || die '请完整解压含 tools 文件夹的 Mac 更新包，或安装 age（brew install age）。'
fi

identity=${1:-${NICE_SSH_IDENTITY:-}}
if [[ -z "$identity" ]]; then
    # Only compare explicitly named public keys with tags in the recovery header.
    LC_ALL=C awk '$1=="---"{exit} $1=="->" && ($2=="ssh-rsa" || $2=="ssh-ed25519"){print $3}' \
        "$recovery" > "$work/recipient-tags"
    for pub in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
        [[ -f "$pub" && -f "${pub%.pub}" ]] || continue
        tag=$(awk 'NR==1{printf "%s",$2;exit}' "$pub" | openssl base64 -d -A |
            openssl dgst -sha256 -binary | head -c 4 | openssl base64 -A | tr -d '=') || continue
        if grep -Fqx -- "$tag" "$work/recipient-tags"; then identity=${pub%.pub}; break; fi
    done
fi
if [[ -z "$identity" ]]; then
    if [[ "$(uname -s)" == Darwin && -t 0 ]]; then
        printf '请选择本机上曾登记到 apple1day GitHub 账号的 SSH 私钥文件。\n'
        if [[ -d "$HOME/.ssh" ]]; then location="$HOME/.ssh"; else location="$HOME"; fi
        identity=$(osascript - "$location" <<'APPLESCRIPT'
on run argv
    return POSIX path of (choose file with prompt "选择与 GitHub 已登记公钥配对的 SSH 私钥文件" default location (POSIX file (item 1 of argv)) with invisibles)
end run
APPLESCRIPT
        ) || die '已取消选择。'
    else
        die '请把对应 SSH 私钥的本机路径作为第一个参数传入，再运行此脚本。'
    fi
fi
[[ -f "$identity" && -r "$identity" && "$identity" != *.pub ]] || die '请选择可读取的 SSH 私钥文件。'
printf '正在本机解封签名备份。如果 SSH 密钥有口令，age 会在终端提示输入。\n'
"$age" --decrypt -i "$identity" -o "$work/recovery.tar" "$recovery" ||
    die '无法解封备份，请核对所选 SSH 私钥和口令。'
tar -xOf "$work/recovery.tar" release.p12 > "$work/store.p12"
tar -xOf "$work/recovery.tar" password.txt > "$work/password"
[[ -s "$work/store.p12" && -s "$work/password" ]] || die '签名备份内容不完整。'
stage=$(mktemp -d "$bundle/.nice-update.XXXXXXXX")
signed="$stage/update.apk"
java -jar "$signer" sign --ks "$work/store.p12" --ks-key-alias nice-mobile \
    --ks-pass "file:$work/password" --key-pass "file:$work/password" \
    --v4-signing-enabled false --out "$signed" "$payload"
verify_owner "$signed" || die '签名校验失败，请核对备份是否属于之前的 1.3.10 安装包。'
same_payload "$payload" "$signed" || die '输出文件内容校验失败。'
mv -n -- "$signed" "$output"
[[ ! -e "$signed" ]] || die '另一个同名安装包已存在，原文件已保留。'
printf '覆盖更新包已生成，可以发送到平板，点开安装。\n%s\n' "$output"
