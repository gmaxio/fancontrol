#!/bin/zsh
# fancontrol 安装脚本
# 1. 安装 CLI 到 ~/.fancontrol/
# 2. 把受限的 smc 二进制安装到系统受保护目录并设置 setuid root
# 3. 创建命令行入口 /usr/local/bin/fancontrol
# 4. 安装 FanControl.app（分发包中存在时）
# 5. 可选: 注册登录时自启的 LaunchAgent
set -e

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/.fancontrol"
PRIV_SMC="/Library/PrivilegedHelperTools/io.github.gmaxio.fancontrol.smc"
AGENT_PLIST="$HOME/Library/LaunchAgents/io.github.gmaxio.fancontrol.cli.plist"

echo "==> 安装 fancontrol 到 $DEST"
if [ ! -x /usr/bin/python3 ]; then
    echo "警告: 未找到 /usr/bin/python3 (Xcode 命令行工具未安装)"
    echo "CLI 需要它; 可运行 xcode-select --install 安装, 或只使用 FanControl.app (无依赖)"
    exit 1
fi
mkdir -p "$DEST/bin" "$HOME/.config/fancontrol"
cp "$SRC/fancontrol.py" "$DEST/bin/fancontrol.py"
chmod +x "$DEST/bin/fancontrol.py"

cat > "$DEST/bin/fancontrol" <<EOF
#!/bin/zsh
export FANCONTROL_SMC="$PRIV_SMC"
exec /usr/bin/python3 "$DEST/bin/fancontrol.py" "\$@"
EOF
chmod +x "$DEST/bin/fancontrol"

echo "==> 设置 smc 特权 (需要管理员密码, 会弹出系统密码框)"
APP_SOURCE=""
if [ -d "$SRC/FanControl.app" ]; then
    APP_SOURCE="$SRC/FanControl.app"
fi

# macOS 的隐私保护可能阻止管理员进程直接读取“文稿”等用户目录。
# 先由当前用户把安装源暂存到 /private/tmp，再交给管理员进程安装。
STAGE_DIR="$(mktemp -d /private/tmp/fancontrol-install.XXXXXX)"
trap 'rm -rf "$STAGE_DIR"' EXIT
cp "$SRC/smc" "$STAGE_DIR/smc"
chmod 755 "$STAGE_DIR/smc"
STAGED_APP=""
if [ -n "$APP_SOURCE" ]; then
    STAGED_APP="$STAGE_DIR/FanControl.app"
    /usr/bin/ditto "$APP_SOURCE" "$STAGED_APP"
fi

if ! osascript - "$STAGE_DIR/smc" "$PRIV_SMC" "$DEST/bin/fancontrol" "$STAGED_APP" <<'APPLESCRIPT' >/dev/null
on run argv
    set smcSource to item 1 of argv
    set smcTarget to item 2 of argv
    set cliSource to item 3 of argv
    set appSource to item 4 of argv
    set commandText to "/usr/bin/install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools" & ¬
        " && /usr/bin/install -o root -g wheel -m 4755 " & quoted form of smcSource & " " & quoted form of smcTarget & ¬
        " && /bin/mkdir -p /usr/local/bin" & ¬
        " && /bin/ln -sf " & quoted form of cliSource & " /usr/local/bin/fancontrol"
    if appSource is not "" then
        set commandText to commandText & " && /usr/bin/ditto " & quoted form of appSource & " /Applications/FanControl.app"
    end if
    do shell script commandText with administrator privileges
end run
APPLESCRIPT
then
    echo "授权被取消或失败。也可以手动执行:"
    echo "  sudo install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools"
    echo "  sudo install -o root -g wheel -m 4755 '$SRC/smc' '$PRIV_SMC'"
    echo "  sudo ln -sf '$DEST/bin/fancontrol' /usr/local/bin/fancontrol"
    exit 1
fi
ln -sf "$PRIV_SMC" "$DEST/bin/smc"

# 校验 setuid 是否生效
if [ "$(stat -f '%Su' "$PRIV_SMC")" != "root" ] ||
   [[ "$(stat -f '%Sp' "$PRIV_SMC")" != *s* ]]; then
    echo "setuid 设置失败, 请检查上面的提示"
    exit 1
fi

echo "==> 注册登录自启 LaunchAgent"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>io.github.gmaxio.fancontrol.cli</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>$DEST/bin/fancontrol.py</string>
        <string>run</string>
        <string>--quiet</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>FANCONTROL_SMC</key>
        <string>$PRIV_SMC</string>
    </dict>
    <key>RunAtLoad</key>
    <false/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF

echo ""
echo "安装完成! 使用方式:"
echo "  fancontrol status        查看状态"
echo "  fancontrol presets       查看预设"
echo "  fancontrol run           前台调速 (Ctrl+C 退出并恢复自动)"
echo "  fancontrol start         后台启动温控服务"
if [ -n "$APP_SOURCE" ]; then
    echo "  open /Applications/FanControl.app"
fi
echo ""
echo "如需开机自动温控: launchctl load $AGENT_PLIST"
echo "(再把 plist 里 RunAtLoad 改为 true)"
