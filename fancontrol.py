#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fancontrol - Apple Silicon Mac 风扇曲线控制工具
提供本地优先的风扇曲线控制:
  - 自定义"温度 -> 转速"曲线
  - 命名预设的保存 / 应用 / 删除 / 切换
  - 后台守护进程按曲线自动调速
  - 退出时自动恢复系统控制

主打 Apple Silicon Mac，并保留经过验证机型的 Intel/T2 兼容路径。
不同芯片和机型的 SMC 行为可能不同，未验证机型默认视为实验性支持。
底层依赖同目录的 smc 通用二进制。
"""

import json
import os
import platform
import re
import signal
import subprocess
import sys
import time

IS_ARM = platform.machine() == "arm64"

# ---------- 路径 ----------

HOME = os.path.expanduser("~")
CONFIG_DIR = os.path.join(HOME, ".config", "fancontrol")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")
PRESETS_FILE = os.path.join(CONFIG_DIR, "presets.json")
LOG_FILE = os.path.join(CONFIG_DIR, "fancontrol.log")
PID_FILE = os.path.join(CONFIG_DIR, "fancontrol.pid")

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SMC_BIN = os.environ.get("FANCONTROL_SMC", os.path.join(SCRIPT_DIR, "smc"))

# ---------- 默认配置 ----------

DEFAULT_CONFIG = {
    "active_preset": "balanced",
    "sensor": "TC0P",          # CPU Proximity
    "interval": 2.0,           # 调速循环间隔(秒)
    "hysteresis_rpm": 80,      # 滞回: 目标转速变化超过该值才写入
    "critical_temp": 95.0,     # 超过该温度强制全速
    "restore_auto_on_exit": True,
}

DEFAULT_PRESETS = {
    "balanced": {
        "description": "均衡: 低温安静, 高温积极",
        "sensor": "TC0P",
        "fans": [0, 1],
        "curve": [[45, 2200], [60, 3000], [70, 4000], [80, 5000], [90, 5927]],
    },
    "silent": {
        "description": "静音优先: 尽量低转",
        "sensor": "TC0P",
        "fans": [0, 1],
        "curve": [[55, 2160], [70, 2800], [80, 3600], [90, 5927]],
    },
    "performance": {
        "description": "性能优先: 提前拉高转速",
        "sensor": "TC0P",
        "fans": [0, 1],
        "curve": [[40, 2600], [55, 3600], [65, 4600], [75, 5927]],
    },
    "full-blast": {
        "description": "全速运转",
        "sensor": "TC0P",
        "fans": [0, 1],
        "curve": [[0, 5927]],
    },
}

# 常用温度传感器(用于 sensors 命令展示)
KNOWN_SENSORS_INTEL = [
    ("TC0P", "CPU Proximity"),
    ("TC0E", "CPU 核心 1"),
    ("TC0F", "CPU 核心 2"),
    ("TC0C", "CPU 核心"),
    ("TG0P", "GPU Proximity"),
    ("TG0D", "GPU Die"),
    ("TB0T", "电池"),
    ("Ts0P", "掌托"),
    ("Ts0S", "内存"),
    ("TW0P", "WiFi"),
    ("Th0H", "硬盘/SSD"),
    ("TA0P", "环境"),
]
KNOWN_SENSORS_ARM = [
    ("Tp0P", "CPU/SoC Proximity"),
    ("Tp01", "传感器 Tp01"),
    ("Tp05", "传感器 Tp05"),
    ("Tp09", "传感器 Tp09"),
    ("Tp0D", "传感器 Tp0D"),
    ("Tp0H", "传感器 Tp0H"),
    ("Tp0L", "传感器 Tp0L"),
    ("Tp0T", "传感器 Tp0T"),
    ("Tp0X", "传感器 Tp0X"),
    ("Tp0b", "传感器 Tp0b"),
    ("TB0T", "电池"),
    ("TW0P", "WiFi"),
]
KNOWN_SENSORS = KNOWN_SENSORS_ARM if IS_ARM else KNOWN_SENSORS_INTEL

ANSII = {"g": "\033[32m", "y": "\033[33m", "r": "\033[31m", "c": "\033[36m", "b": "\033[1m", "0": "\033[0m"}


def color(s, c):
    if not sys.stdout.isatty():
        return s
    return ANSII.get(c, "") + str(s) + ANSII["0"]


def info(msg):
    print(color("ℹ ", "c") + msg)


def ok(msg):
    print(color("✓ ", "g") + msg)


def warn(msg):
    print(color("⚠ ", "y") + msg, file=sys.stderr)


def die(msg, code=1):
    print(color("✗ ", "r") + msg, file=sys.stderr)
    sys.exit(code)


# ---------- 配置读写 ----------

def load_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return default


def save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


def load_config():
    cfg = DEFAULT_CONFIG.copy()
    cfg.update(load_json(CONFIG_FILE, {}))
    return cfg


def load_presets():
    presets = load_json(PRESETS_FILE, {})
    if not presets:
        presets = dict(DEFAULT_PRESETS)
        save_json(PRESETS_FILE, presets)
    return presets


# ---------- SMC 调用 ----------

class SMCError(Exception):
    pass


def smc_run(*args):
    if not os.path.exists(SMC_BIN):
        die(f"找不到 smc 二进制: {SMC_BIN}\n请先运行 install.sh 安装")
    try:
        p = subprocess.run([SMC_BIN] + list(args),
                           capture_output=True, text=True, timeout=5)
    except subprocess.TimeoutExpired:
        raise SMCError("smc 调用超时")
    out = (p.stdout or "").strip()
    err = (p.stderr or "").strip()
    if p.returncode != 0:
        raise SMCError(err or out or f"smc 返回码 {p.returncode}")
    return out


def smc_read(key):
    """读取一个键, 返回浮点值"""
    out = smc_run("-r", key)
    m = re.match(r"^-?\d+(\.\d+)?", out)
    if not m:
        raise SMCError(f"无法解析 {key} 的读数: {out!r}")
    return float(m.group(0))


def smc_write(key, value):
    smc_run("-w", key, str(value))


def read_temp(sensor):
    try:
        return smc_read(sensor)
    except SMCError as e:
        raise SMCError(f"读取传感器 {sensor} 失败: {e}")


# 温度传感器回退探测列表 (参考 smcFanControl/stats)
INTEL_SENSOR_FALLBACK = ["TC0P", "TC0E", "TC0F", "TC0C", "TCAD", "TCAH", "TCBH"]
ARM_SENSOR_FALLBACK = ["Tp0P", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0H",
                       "Tp0L", "Tp0T", "Tp0X", "Tp0b"]

_sensor_cache = {}


def resolve_sensor(preferred):
    """优先用配置传感器; 读不出则按架构回退探测, 返回 (键名, 读数)"""
    try:
        return preferred, read_temp(preferred)
    except SMCError:
        pass
    if preferred in _sensor_cache:
        s = _sensor_cache[preferred]
        try:
            return s, read_temp(s)
        except SMCError:
            pass
    for s in (ARM_SENSOR_FALLBACK if IS_ARM else INTEL_SENSOR_FALLBACK):
        try:
            v = read_temp(s)
            _sensor_cache[preferred] = s
            return s, v
        except SMCError:
            continue
    raise SMCError("没有可用的温度传感器")


# ---------- 风扇模式键与写入重试 (Apple Silicon 适配) ----------

_mode_key_cache = {}


def mode_key(fid):
    """Intel 用 F{id}Md; Apple Silicon 探测小写 F{id}md (参考 stats)"""
    if fid in _mode_key_cache:
        return _mode_key_cache[fid]
    key = f"F{fid}Md"
    if IS_ARM:
        try:
            smc_read(f"F{fid}md")
            key = f"F{fid}md"
        except SMCError:
            key = f"F{fid}Md"
    _mode_key_cache[fid] = key
    return key


def smc_write_retry(key, value, attempts=10, delay=0.05):
    for i in range(attempts):
        try:
            smc_write(key, value)
            return True
        except SMCError:
            if i < attempts - 1:
                time.sleep(delay)
    return False


def unlock_fan_control(fid):
    """Apple Silicon 解锁风扇控制 (Ftst 握手, 参考 stats)"""
    key = mode_key(fid)
    try:
        if int(smc_read(key)) == 1:
            return True
    except SMCError:
        return False
    # 先尝试直接写模式键 (部分新机型无需 Ftst)
    if smc_write_retry(key, 1, attempts=2):
        return True
    # Ftst 解锁流程 (M1-M4)
    try:
        ftst = smc_read("Ftst")
    except SMCError:
        return False
    if int(ftst) == 1:
        return smc_write_retry(key, 1, attempts=20, delay=0.1)
    if not smc_write_retry("Ftst", 1, attempts=100):
        return False
    time.sleep(3)  # 等 thermalmonitord 让出控制权
    return smc_write_retry(key, 1, attempts=300, delay=0.1)


def get_fans():
    """返回 [{id, rpm, min, max, target, mode}]"""
    out = smc_run("-f")
    fans = []
    for m in re.finditer(r"风扇 (\d+): 当前=([\d.]+) RPM 最小=([\d.]+) 最大=([\d.]+) 目标=([\d.]+)", out):
        fid = int(m.group(1))
        mode = None
        try:
            mode = int(smc_read(mode_key(fid)))
        except SMCError:
            pass
        fans.append({
            "id": fid, "rpm": float(m.group(2)), "min": float(m.group(3)),
            "max": float(m.group(4)), "target": float(m.group(5)),
            "mode": mode,  # 0=自动 1=强制 None=未知
        })
    return fans


def set_fan_mode_auto(fid):
    """恢复某风扇为系统自动控制"""
    if IS_ARM:
        ok = smc_write_retry(mode_key(fid), 0, attempts=10)
        smc_write_retry(f"F{fid}Tg", 0, attempts=5)
        # 清掉 Ftst 解锁状态
        try:
            if int(smc_read("Ftst")) == 1:
                smc_write_retry("Ftst", 0, attempts=10)
        except SMCError:
            pass
        return ok
    try:
        smc_write(f"F{fid}Md", 0)
        return True
    except SMCError:
        # 老机型回退到 FS! 位操作
        try:
            cur = int(smc_read("FS! "))
            smc_write("FS! ", cur & ~(1 << fid))
            return True
        except SMCError:
            return False


def set_fan_manual(fid, rpm):
    """设定某风扇为手动模式并写入目标转速"""
    fans = get_fans()
    f = next((x for x in fans if x["id"] == fid), None)
    if f is None:
        raise SMCError(f"风扇 {fid} 不存在")
    rpm = max(f["min"], min(f["max"], rpm))
    if IS_ARM:
        if f["mode"] != 1 and not unlock_fan_control(fid):
            raise SMCError("无法解锁风扇控制 (Ftst 握手失败)")
        if not smc_write_retry(f"F{fid}Tg", int(rpm), attempts=10):
            raise SMCError(f"写入 F{fid}Tg 失败")
        return rpm
    # Intel: 先确保进入强制模式
    if f["mode"] != 1:
        try:
            smc_write(f"F{fid}Md", 1)
        except SMCError:
            try:
                cur = int(smc_read("FS! "))
                smc_write("FS! ", cur | (1 << fid))
            except SMCError as e:
                raise SMCError(f"无法进入手动模式: {e}")
    smc_write(f"F{fid}Tg", int(rpm))
    return rpm


# ---------- 曲线计算 ----------

def curve_to_rpm(curve, temp):
    """曲线插值: curve = [[temp, rpm], ...] 按温度升序"""
    if not curve:
        raise SMCError("曲线为空")
    pts = sorted(curve, key=lambda p: p[0])
    if temp <= pts[0][0]:
        return float(pts[0][1])
    if temp >= pts[-1][0]:
        return float(pts[-1][1])
    for i in range(len(pts) - 1):
        t0, r0 = pts[i]
        t1, r1 = pts[i + 1]
        if t0 <= temp <= t1:
            if t1 == t0:
                return float(r1)
            ratio = (temp - t0) / (t1 - t0)
            return r0 + ratio * (r1 - r0)
    return float(pts[-1][1])


def validate_curve(curve):
    if not isinstance(curve, list) or not curve:
        die("曲线必须是非空的 [[温度, 转速], ...] 列表")
    for p in curve:
        if (not isinstance(p, (list, tuple)) or len(p) != 2
                or not all(isinstance(x, (int, float)) for x in p)):
            die(f"曲线点格式错误: {p!r}, 应为 [温度, 转速]")
        if not (-20 <= p[0] <= 130):
            die(f"曲线温度 {p[0]} 超出合理范围")
        if not (0 <= p[1] <= 12000):
            die(f"曲线转速 {p[1]} 超出合理范围")


def parse_curve(text):
    """解析 '40:2200,55:3000,70:4200' 形式的曲线"""
    pts = []
    for seg in text.split(","):
        seg = seg.strip()
        if not seg:
            continue
        m = re.match(r"^(-?\d+(?:\.\d+)?)[:@](\d+(?:\.\d+)?)$", seg)
        if not m:
            die(f"无法解析曲线段: {seg!r}, 格式应为 温度:转速")
        pts.append([float(m.group(1)), float(m.group(2))])
    validate_curve(pts)
    return pts


# ---------- 温控循环 ----------

class Controller:
    def __init__(self, preset, cfg, quiet=False, keep_on_exit=False):
        self.preset = preset
        self.cfg = cfg
        self.quiet = quiet
        self.keep_on_exit = keep_on_exit
        self.sensor = preset.get("sensor") or cfg["sensor"]
        self.fan_ids = preset.get("fans", [0, 1])
        self.curve = preset["curve"]
        self.last_target = {}     # fid -> 上次写入的 rpm
        self.running = True
        self.touched = set()      # 被我们接管过的风扇(退出时恢复)

    def log(self, msg):
        line = time.strftime("[%H:%M:%S] ") + msg
        if not self.quiet:
            print(line, flush=True)
        else:
            try:
                os.makedirs(CONFIG_DIR, exist_ok=True)
                with open(LOG_FILE, "a", encoding="utf-8") as f:
                    f.write(line + "\n")
            except OSError:
                pass

    def stop(self, *_):
        self.running = False

    def restore_auto(self):
        for fid in sorted(self.touched):
            if set_fan_mode_auto(fid):
                self.log(f"风扇 {fid} 已恢复系统自动控制")
            else:
                self.log(f"风扇 {fid} 恢复自动失败, 请手动执行 fancontrol auto")

    def _temp(self, sensor, temp_cache):
        """读温度(带传感器回退探测与 tick 级缓存), 返回 (实际键名, 读数)"""
        if sensor in temp_cache:
            return temp_cache[sensor]
        key, value = resolve_sensor(sensor)
        temp_cache[sensor] = (key, value)
        return key, value

    def _fan_target(self, fid, f, critical, temp_cache):
        """计算单个风扇的目标转速; 返回 None 表示交给系统自动控制"""
        per_fan = self.preset.get("perFan") or {}
        fc = per_fan.get(str(fid))
        if fc:
            mode = fc.get("mode", "auto")
            if mode == "auto":
                return None, None
            if mode == "fixed":
                return float(fc.get("rpm", f["min"])), None
            if mode == "curve":
                sensor = fc.get("sensor") or self.sensor
                key, t = self._temp(sensor, temp_cache)
                if t >= critical:
                    return f["max"], (key, t)
                return curve_to_rpm(fc.get("curve", []), t), (key, t)
            return None, None
        # 无 perFan: 共享曲线
        key, t = self._temp(self.sensor, temp_cache)
        if t >= critical:
            return f["max"], (key, t)
        return curve_to_rpm(self.curve, t), (key, t)

    def run(self):
        signal.signal(signal.SIGINT, self.stop)
        signal.signal(signal.SIGTERM, self.stop)
        interval = float(self.cfg["interval"])
        hysteresis = float(self.cfg["hysteresis_rpm"])
        critical = float(self.cfg["critical_temp"])
        self.log(f"温控循环启动 | 预设={self.preset_name} 传感器={self.sensor} "
                 f"风扇={self.fan_ids} 间隔={interval}s")
        try:
            while self.running:
                temp_cache = {}
                fans = get_fans()
                fmap = {f["id"]: f for f in fans}
                desc = []
                for fid in self.fan_ids:
                    f = fmap.get(fid)
                    if f is None:
                        continue
                    try:
                        target, tinfo = self._fan_target(fid, f, critical, temp_cache)
                    except SMCError as e:
                        self.log(f"风扇 {fid} 读温度失败: {e}")
                        continue

                    if target is None:
                        # 该风扇设为自动: 若之前被接管过则归还系统
                        if fid in self.touched:
                            if set_fan_mode_auto(fid):
                                self.touched.discard(fid)
                                self.last_target.pop(fid, None)
                                self.log(f"风扇 {fid} 切换为系统自动控制")
                        continue

                    tgt = max(f["min"], min(f["max"], target))
                    last = self.last_target.get(fid)
                    if last is None or abs(tgt - last) >= hysteresis:
                        try:
                            applied = set_fan_manual(fid, tgt)
                            self.last_target[fid] = applied
                            self.touched.add(fid)
                        except SMCError as e:
                            self.log(f"风扇 {fid} 调速失败: {e}")
                            continue
                    d = f"F{fid}={f['rpm']:.0f}→{self.last_target.get(fid, 0):.0f}"
                    if tinfo:
                        d += f"({tinfo[0]}={tinfo[1]:.1f}°C)"
                    desc.append(d)
                if desc:
                    self.log("  ".join(desc))
                time.sleep(interval)
        finally:
            if self.keep_on_exit:
                self.log("退出, 保持当前转速设置")
            else:
                self.log("退出, 恢复系统自动控制...")
                self.restore_auto()


# ---------- 命令实现 ----------

def cmd_status(_):
    cfg = load_config()
    presets = load_presets()
    name = cfg.get("active_preset", "-")
    sensor = cfg.get("sensor", "TC0P")
    print(color("● 风扇控制状态", "b") + color(f"  ({'Apple Silicon' if IS_ARM else 'Intel'})", "c"))
    try:
        key, t = resolve_sensor(sensor)
        print(f"  {key} 温度: {color(f'{t:.1f}°C', 'y' if t > 80 else 'g')}")
    except SMCError as e:
        warn(str(e))
    try:
        for f in get_fans():
            mode = {0: color("自动", "g"), 1: color("手动", "y")}.get(f["mode"], "未知")
            rpm_str = "%.0f RPM" % f["rpm"]
            print(f"  风扇 {f['id']}: {color(rpm_str, 'c')} "
                  f"(范围 {f['min']:.0f}-{f['max']:.0f}, 目标 {f['target']:.0f}) 模式={mode}")
    except SMCError as e:
        warn(str(e))
    print(f"  激活预设: {color(name, 'c')}")
    p = presets.get(name)
    if p:
        pts = "  ".join(f"{t:g}°C→{r:g}" for t, r in sorted(p["curve"]))
        print(f"  曲线: {pts}")
    pid = load_json(PID_FILE, {}).get("pid")
    if pid and _pid_alive(pid):
        print(f"  后台服务: {color('运行中', 'g')} (pid {pid})")
    else:
        print(f"  后台服务: 未运行")


def _pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError):
        return False


def cmd_sensors(_):
    print(color("● 温度传感器", "b"))
    for key, label in KNOWN_SENSORS:
        try:
            v = smc_read(key)
            print(f"  {key}  {label:<14} {color(f'{v:.1f}°C', 'g')}")
        except SMCError:
            pass


def cmd_fans(_):
    print(color("● 风扇信息", "b"))
    for f in get_fans():
        mode = {0: "自动", 1: "手动"}.get(f["mode"], "未知")
        print(f"  风扇 {f['id']}: 当前 {f['rpm']:.0f} RPM | 最小 {f['min']:.0f} | "
              f"最大 {f['max']:.0f} | 目标 {f['target']:.0f} | 模式: {mode}")


def cmd_set(args):
    if len(args) != 2:
        die("用法: fancontrol set <风扇编号> <转速RPM>")
    fid = int(args[0])
    rpm = float(args[1])
    applied = set_fan_manual(fid, rpm)
    ok(f"风扇 {fid} 已设为 {applied:.0f} RPM (手动模式)")
    warn("提示: 用 fancontrol auto 可恢复系统自动控制")


def cmd_auto(args):
    fans = get_fans()
    ids = [int(a) for a in args] if args else [f["id"] for f in fans]
    for fid in ids:
        if set_fan_mode_auto(fid):
            ok(f"风扇 {fid} 已恢复系统自动控制")
        else:
            warn(f"风扇 {fid} 恢复失败")


def cmd_presets(_):
    cfg = load_config()
    presets = load_presets()
    active = cfg.get("active_preset")
    print(color("● 风扇预设", "b"))
    for name, p in presets.items():
        mark = color("▶ ", "g") if name == active else "  "
        desc = p.get("description", "")
        pts = "  ".join(f"{t:g}°C→{r:g}" for t, r in sorted(p["curve"]))
        print(f"{mark}{color(name, 'c')}  ({p.get('sensor', 'TC0P')})  {desc}")
        print(f"      {pts}")


def cmd_save(args):
    if not args:
        die("用法: fancontrol save <预设名> [描述]")
    name = args[0]
    desc = args[1] if len(args) > 1 else ""
    presets = load_presets()
    if name in presets:
        warn(f"预设 {name!r} 已存在, 将被覆盖")
    # 保存当前配置: 若已有激活曲线则沿用, 否则用 balanced 模板
    cfg = load_config()
    cur = presets.get(cfg.get("active_preset"), DEFAULT_PRESETS["balanced"])
    presets[name] = {
        "description": desc or cur.get("description", "自定义预设"),
        "sensor": cur.get("sensor", cfg.get("sensor", "TC0P")),
        "fans": cur.get("fans", [0, 1]),
        "curve": cur["curve"],
        "custom": True,
    }
    save_json(PRESETS_FILE, presets)
    ok(f"已保存预设 {name!r}")
    info("用 fancontrol set-curve 修改它的曲线, 用 fancontrol apply 启用")


def cmd_apply(args):
    if not args:
        die("用法: fancontrol apply <预设名>")
    name = args[0]
    presets = load_presets()
    if name not in presets:
        die(f"预设 {name!r} 不存在, 用 fancontrol presets 查看")
    cfg = load_config()
    cfg["active_preset"] = name
    save_json(CONFIG_FILE, cfg)
    ok(f"已激活预设 {name!r}")
    pid = load_json(PID_FILE, {}).get("pid")
    if pid and _pid_alive(pid):
        info("后台服务正在运行, 重启以应用新预设...")
        _service_stop()
        _service_start()
    else:
        info("运行 fancontrol run 前台调速, 或 fancontrol start 后台运行")


def cmd_delete(args):
    if not args:
        die("用法: fancontrol delete <预设名>")
    name = args[0]
    presets = load_presets()
    if name not in presets:
        die(f"预设 {name!r} 不存在")
    if name in DEFAULT_PRESETS:
        warn(f"{name!r} 是内置预设, 删除后可用 fancontrol reset 恢复")
    del presets[name]
    save_json(PRESETS_FILE, presets)
    cfg = load_config()
    if cfg.get("active_preset") == name:
        cfg["active_preset"] = "balanced"
        save_json(CONFIG_FILE, cfg)
        warn("激活预设已切换回 balanced")
    ok(f"已删除预设 {name!r}")


def cmd_reset(_):
    save_json(PRESETS_FILE, dict(DEFAULT_PRESETS))
    ok("已恢复全部内置预设")


def cmd_set_curve(args):
    if len(args) != 2:
        die("用法: fancontrol set-curve <预设名> <曲线>\n"
            "例:  fancontrol set-curve quiet \"45:2200,60:3000,70:4200,85:5927\"")
    name, text = args
    pts = parse_curve(text)
    presets = load_presets()
    if name not in presets:
        die(f"预设 {name!r} 不存在, 先用 fancontrol save {name} 创建")
    presets[name]["curve"] = pts
    save_json(PRESETS_FILE, presets)
    ok(f"预设 {name!r} 曲线已更新:")
    print("      " + "  ".join(f"{t:g}°C→{r:g}" for t, r in sorted(pts)))


def cmd_set_sensor(args):
    if len(args) != 2:
        die("用法: fancontrol set-sensor <预设名> <传感器键>\n"
            "例:  fancontrol set-sensor quiet TC0E\n"
            "用 fancontrol sensors 查看可用传感器")
    name, sensor = args
    presets = load_presets()
    if name not in presets:
        die(f"预设 {name!r} 不存在")
    try:
        smc_read(sensor)
    except SMCError:
        die(f"传感器 {sensor} 在此机器上不可读")
    presets[name]["sensor"] = sensor
    save_json(PRESETS_FILE, presets)
    ok(f"预设 {name!r} 已改用传感器 {sensor}")


def cmd_run(args):
    cfg = load_config()
    presets = load_presets()
    name = cfg.get("active_preset")
    preset = presets.get(name)
    if preset is None:
        die(f"激活预设 {name!r} 不存在")
    quiet = "--quiet" in args
    keep = "--keep" in args
    _check_mfc()
    ctl = Controller(preset, cfg, quiet=quiet, keep_on_exit=keep)
    ctl.preset_name = name
    try:
        ctl.run()
    except SMCError as e:
        die(str(e))


def _check_mfc():
    try:
        p = subprocess.run(["pgrep", "-fl", "Macs Fan Control"],
                           capture_output=True, text=True, timeout=3)
        if p.returncode == 0 and p.stdout.strip():
            warn("检测到 Macs Fan Control 正在运行, 两者会争夺风扇控制权, 建议先退出它")
    except Exception:
        pass


def cmd_start(_):
    cfg = load_config()
    presets = load_presets()
    if cfg.get("active_preset") not in presets:
        die("激活预设不存在")
    pid = load_json(PID_FILE, {}).get("pid")
    if pid and _pid_alive(pid):
        warn(f"后台服务已在运行 (pid {pid})")
        return
    _check_mfc()
    _service_start()


def _service_start():
    os.makedirs(CONFIG_DIR, exist_ok=True)
    log = open(LOG_FILE, "a")
    p = subprocess.Popen(
        [sys.executable, os.path.abspath(__file__), "run", "--quiet"],
        stdout=log, stderr=log, stdin=subprocess.DEVNULL,
        start_new_session=True)
    save_json(PID_FILE, {"pid": p.pid})
    time.sleep(0.5)
    if _pid_alive(p.pid):
        ok(f"后台温控服务已启动 (pid {p.pid}), 日志: {LOG_FILE}")
    else:
        die("服务启动失败, 请运行 fancontrol run 查看错误")


def _service_stop():
    pid = load_json(PID_FILE, {}).get("pid")
    if pid and _pid_alive(pid):
        os.kill(int(pid), signal.SIGTERM)
        for _ in range(30):
            if not _pid_alive(pid):
                break
            time.sleep(0.1)
    save_json(PID_FILE, {})


def cmd_stop(_):
    pid = load_json(PID_FILE, {}).get("pid")
    if not pid or not _pid_alive(pid):
        warn("后台服务未在运行")
        save_json(PID_FILE, {})
        return
    _service_stop()
    ok("后台温控服务已停止 (风扇已恢复系统自动控制)")


def cmd_log(_):
    if not os.path.exists(LOG_FILE):
        info("暂无日志")
        return
    try:
        subprocess.run(["tail", "-n", "30", LOG_FILE])
    except KeyboardInterrupt:
        pass


USAGE = f"""{color('fancontrol - MacBook 风扇曲线控制', 'b')}

{color('监控:', 'y')}
  status                温度/风扇/预设 总览
  sensors               列出可用温度传感器
  fans                  风扇详细信息

{color('手动控制:', 'y')}
  set <风扇> <RPM>      手动设定转速
  auto [风扇]           恢复系统自动控制(默认全部)

{color('预设管理(核心功能):', 'y')}
  presets               列出所有预设
  save <名> [描述]      保存新预设
  apply <名>            应用预设
  delete <名>           删除预设
  set-curve <名> <曲线> 设置曲线, 如 "45:2200,60:3000,75:4800,90:5927"
  set-sensor <名> <键>  更换预设的温度传感器(默认 TC0P)
  reset                 恢复内置预设

{color('自动调速:', 'y')}
  run [--keep]          前台按激活预设调速(退出恢复自动, --keep 则保持)
  start                 后台启动温控服务
  stop                  停止后台服务(恢复自动)
  log                   查看服务日志

内置预设: balanced / silent / performance / full-blast
配置文件: {CONFIG_DIR}
"""


def main():
    cmds = {
        "status": cmd_status, "sensors": cmd_sensors, "fans": cmd_fans,
        "set": cmd_set, "auto": cmd_auto,
        "presets": cmd_presets, "save": cmd_save, "apply": cmd_apply,
        "delete": cmd_delete, "reset": cmd_reset,
        "set-curve": cmd_set_curve, "set-sensor": cmd_set_sensor,
        "run": cmd_run, "start": cmd_start, "stop": cmd_stop, "log": cmd_log,
    }
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help", "help"):
        print(USAGE)
        return
    cmd = sys.argv[1]
    fn = cmds.get(cmd)
    if fn is None:
        print(USAGE)
        die(f"未知命令: {cmd}")
    fn(sys.argv[2:])


if __name__ == "__main__":
    main()
