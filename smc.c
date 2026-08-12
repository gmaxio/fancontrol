/*
 * smc.c - SMC (System Management Controller) read/write utility
 * Copyright (C) 2006 devnull
 * Portions Copyright (C) 2013 Michael Wilber
 * Modifications Copyright (C) 2026 gmaxio
 *
 * Derived from the smc-command component of smcFanControl and adapted for
 * current macOS SMC command values, Apple Silicon compatibility, and a
 * deliberately restricted fan-control write surface. See NOTICE.
 *
 * This file is licensed under GPL-2.0-or-later. See LICENSE.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include <unistd.h>
#include <IOKit/IOKitLib.h>

#define KERNEL_INDEX_SMC 2

/* 命令值参考 exelban/stats 与 beltex/smc(适用于现代 macOS)
 * 旧版 smcFanControl 的 8/9/10/11/12/13 在新系统上会被静默忽略(返回全零) */
#define SMC_CMD_READ_BYTES   5
#define SMC_CMD_WRITE_BYTES  6
#define SMC_CMD_READ_INDEX   8
#define SMC_CMD_READ_KEYINFO 9
#define SMC_CMD_READ_PLIMIT  11
#define SMC_CMD_READ_VERS    12

typedef struct {
    char   major;
    char   minor;
    char   build;
    char   reserved[1];
    UInt16 release;
} SMCKeyData_vers_t;

typedef struct {
    UInt16 version;
    UInt16 length;
    UInt32 cpuPLimit;
    UInt32 gpuPLimit;
    UInt32 memPLimit;
} SMCKeyData_pLimitData_t;

typedef struct {
    UInt32 dataSize;
    UInt32 dataType;
    char   dataAttributes;
} SMCKeyData_keyInfo_t;

typedef char SMCBytes_t[32];

typedef struct {
    UInt32                 key;
    SMCKeyData_vers_t      vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t   keyInfo;
    char                   result;
    char                   status;
    char                   data8;
    UInt32                 data32;
    SMCBytes_t             bytes;
} SMCKeyData_t;

typedef char UInt32Char_t[5];

typedef struct {
    UInt32Char_t key;
    UInt32       dataSize;
    UInt32Char_t dataType;
    SMCBytes_t   bytes;
} SMCVal_t;

static IOReturn SMCOpen(io_connect_t *conn)
{
    CFMutableDictionaryRef matching = IOServiceMatching("AppleSMC");
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (service == IO_OBJECT_NULL) {
        fprintf(stderr, "错误: 找不到 AppleSMC 服务\n");
        return kIOReturnError;
    }
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, conn);
    IOObjectRelease(service);
    return result;
}

static IOReturn SMCClose(io_connect_t conn)
{
    return IOServiceClose(conn);
}

static IOReturn SMCCall(io_connect_t conn, int index,
                        SMCKeyData_t *inS, SMCKeyData_t *outS)
{
    size_t inSize = sizeof(SMCKeyData_t);
    size_t outSize = sizeof(SMCKeyData_t);
    return IOConnectCallStructMethod(conn, index, inS, inSize, outS, &outSize);
}

static IOReturn SMCReadKeyInfo(io_connect_t conn, const char *keyStr,
                               SMCKeyData_keyInfo_t *keyInfo)
{
    SMCKeyData_t inS, outS;
    memset(&inS, 0, sizeof(inS));
    memset(&outS, 0, sizeof(outS));

    inS.key = ((uint32_t)keyStr[0] << 24) | ((uint32_t)keyStr[1] << 16) |
              ((uint32_t)keyStr[2] << 8)  | ((uint32_t)keyStr[3]);
    inS.data8 = SMC_CMD_READ_KEYINFO;

    IOReturn ret = SMCCall(conn, KERNEL_INDEX_SMC, &inS, &outS);
    if (ret != kIOReturnSuccess || outS.result != 0)
        return kIOReturnError;

    *keyInfo = outS.keyInfo;
    return kIOReturnSuccess;
}

static IOReturn SMCReadKey(io_connect_t conn, const char *keyStr, SMCVal_t *val)
{
    SMCKeyData_t inS, outS;
    memset(&inS, 0, sizeof(inS));
    memset(&outS, 0, sizeof(outS));

    inS.key = ((uint32_t)keyStr[0] << 24) | ((uint32_t)keyStr[1] << 16) |
              ((uint32_t)keyStr[2] << 8)  | ((uint32_t)keyStr[3]);
    inS.data8 = SMC_CMD_READ_KEYINFO;

    IOReturn ret = SMCCall(conn, KERNEL_INDEX_SMC, &inS, &outS);
    if (ret != kIOReturnSuccess || outS.result != 0)
        return kIOReturnError;

    snprintf(val->dataType, 5, "%c%c%c%c",
             (char)(outS.keyInfo.dataType >> 24),
             (char)(outS.keyInfo.dataType >> 16),
             (char)(outS.keyInfo.dataType >> 8),
             (char)(outS.keyInfo.dataType));
    val->dataSize = outS.keyInfo.dataSize;

    inS.keyInfo.dataSize = val->dataSize;
    inS.data8 = SMC_CMD_READ_BYTES;

    ret = SMCCall(conn, KERNEL_INDEX_SMC, &inS, &outS);
    if (ret != kIOReturnSuccess || outS.result != 0)
        return kIOReturnError;

    memcpy(val->bytes, outS.bytes, sizeof(outS.bytes));
    snprintf(val->key, 5, "%s", keyStr);
    return kIOReturnSuccess;
}

/* 写入前自动读取 keyinfo 获取类型与大小 */
static IOReturn SMCWriteKey(io_connect_t conn, const char *keyStr,
                            const uint8_t *data, uint32_t size)
{
    if (size > sizeof(SMCBytes_t))
        return kIOReturnBadArgument;
    SMCKeyData_t inS, outS;
    memset(&inS, 0, sizeof(inS));
    memset(&outS, 0, sizeof(outS));

    inS.key = ((uint32_t)keyStr[0] << 24) | ((uint32_t)keyStr[1] << 16) |
              ((uint32_t)keyStr[2] << 8)  | ((uint32_t)keyStr[3]);
    inS.keyInfo.dataSize = size;
    inS.data8 = SMC_CMD_WRITE_BYTES;
    memcpy(inS.bytes, data, size);

    IOReturn ret = SMCCall(conn, KERNEL_INDEX_SMC, &inS, &outS);
    if (ret != kIOReturnSuccess || outS.result != 0)
        return kIOReturnError;
    return kIOReturnSuccess;
}

/* ---------- 类型解码 ---------- */

static float decode_fpe2(const uint8_t *b)
{
    return ((uint16_t)b[0] << 8 | b[1]) / 4.0f;
}

static float decode_sp78(const uint8_t *b)
{
    return (int16_t)((uint16_t)b[0] << 8 | b[1]) / 256.0f;
}

/* flt 类型在现代 Mac 上为小端序(参考 exelban/stats) */
static float decode_flt(const uint8_t *b)
{
    float f;
    memcpy(&f, b, 4);
    return f;
}

/* Read a hardware-reported fan RPM limit. Only the two formats observed for
 * fan RPM keys are accepted; an unknown format must fail closed for writes. */
static int read_fan_rpm_limit(io_connect_t conn, int fan, const char *suffix,
                              double *result)
{
    char key[5];
    SMCVal_t value;
    snprintf(key, sizeof(key), "F%d%s", fan, suffix);
    if (SMCReadKey(conn, key, &value) != kIOReturnSuccess)
        return -1;
    if (strcmp(value.dataType, "flt ") == 0 && value.dataSize >= 4) {
        *result = decode_flt((const uint8_t *)value.bytes);
        return isfinite(*result) && *result > 0 ? 0 : -1;
    }
    if (strcmp(value.dataType, "fpe2") == 0 && value.dataSize >= 2) {
        *result = decode_fpe2((const uint8_t *)value.bytes);
        return isfinite(*result) && *result > 0 ? 0 : -1;
    }
    return -1;
}

static void print_value(SMCVal_t *val)
{
    const uint8_t *b = (const uint8_t *)val->bytes;
    const char *t = val->dataType;

    if (strcmp(t, "fpe2") == 0)
        printf("%.2f", decode_fpe2(b));
    else if (strcmp(t, "sp78") == 0)
        printf("%.2f", decode_sp78(b));
    else if (strcmp(t, "flt ") == 0)
        printf("%.2f", decode_flt(b));
    else if (strcmp(t, "ui8 ") == 0)
        printf("%u", b[0]);
    else if (strcmp(t, "ui16") == 0)
        printf("%u", ((uint16_t)b[0] << 8) | b[1]);
    else if (strcmp(t, "ui32") == 0)
        printf("%u", ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) |
                     ((uint32_t)b[2] << 8) | b[3]);
    else if (strcmp(t, "si8 ") == 0)
        printf("%d", (int8_t)b[0]);
    else if (strcmp(t, "si16") == 0)
        printf("%d", (int16_t)(((uint16_t)b[0] << 8) | b[1]));
    else if (strcmp(t, "flag") == 0)
        printf("%s", b[0] ? "true" : "false");
    else if (strcmp(t, "pwm ") == 0)
        printf("%.1f%%", ((uint16_t)b[0] << 8 | b[1]) * 100.0f / 65535.0f);
    else if (strncmp(t, "ch8*", 4) == 0) {
        printf("\"");
        for (uint32_t i = 0; i < val->dataSize && i < 32; i++)
            if (b[i]) printf("%c", b[i]);
        printf("\"");
    }
    else {
        printf("0x");
        for (uint32_t i = 0; i < val->dataSize && i < 32; i++)
            printf("%02x", b[i]);
    }
}

/* ---------- 类型编码 ---------- */

static int encode_value(const char *type, double v, uint8_t *out, uint32_t *size)
{
    if (strcmp(type, "fpe2") == 0) {
        uint16_t x = (uint16_t)(v * 4.0);
        out[0] = (x >> 8) & 0xff; out[1] = x & 0xff;
        *size = 2;
    } else if (strcmp(type, "sp78") == 0) {
        int16_t x = (int16_t)(v * 256.0);
        out[0] = (x >> 8) & 0xff; out[1] = x & 0xff;
        *size = 2;
    } else if (strcmp(type, "flt ") == 0) {
        float f = (float)v;
        memcpy(out, &f, 4); /* 小端序 */
        *size = 4;
    } else if (strcmp(type, "ui8 ") == 0) {
        out[0] = (uint8_t)v;
        *size = 1;
    } else if (strcmp(type, "ui16") == 0) {
        uint16_t x = (uint16_t)v;
        out[0] = (x >> 8) & 0xff; out[1] = x & 0xff;
        *size = 2;
    } else if (strcmp(type, "ui32") == 0) {
        uint32_t x = (uint32_t)v;
        out[0] = (x >> 24) & 0xff; out[1] = (x >> 16) & 0xff;
        out[2] = (x >> 8) & 0xff;  out[3] = x & 0xff;
        *size = 4;
    } else if (strcmp(type, "flag") == 0) {
        out[0] = (v != 0) ? 1 : 0;
        *size = 1;
    } else {
        return -1;
    }
    return 0;
}

/* ---------- 命令实现 ---------- */

static int cmd_list(io_connect_t conn)
{
    SMCVal_t val;
    if (SMCReadKey(conn, "#KEY", &val) != kIOReturnSuccess) {
        fprintf(stderr, "错误: 无法读取键数量\n");
        return 1;
    }
    uint32_t total = ((uint32_t)(uint8_t)val.bytes[0] << 24) |
                     ((uint32_t)(uint8_t)val.bytes[1] << 16) |
                     ((uint32_t)(uint8_t)val.bytes[2] << 8) |
                     (uint8_t)val.bytes[3];

    for (uint32_t i = 0; i < total; i++) {
        SMCKeyData_t inS, outS;
        memset(&inS, 0, sizeof(inS));
        memset(&outS, 0, sizeof(outS));
        inS.data8 = SMC_CMD_READ_INDEX;
        inS.data32 = i;
        if (SMCCall(conn, KERNEL_INDEX_SMC, &inS, &outS) != kIOReturnSuccess)
            continue;

        char keyStr[5];
        keyStr[0] = (outS.key >> 24) & 0xff;
        keyStr[1] = (outS.key >> 16) & 0xff;
        keyStr[2] = (outS.key >> 8) & 0xff;
        keyStr[3] = outS.key & 0xff;
        keyStr[4] = 0;

        SMCVal_t v;
        if (SMCReadKey(conn, keyStr, &v) == kIOReturnSuccess) {
            printf("%-6s [%-4s] ", keyStr, v.dataType);
            print_value(&v);
            printf("\n");
        } else {
            printf("%-6s (不可读)\n", keyStr);
        }
    }
    return 0;
}

static int cmd_read(io_connect_t conn, const char *key)
{
    SMCVal_t val;
    if (SMCReadKey(conn, key, &val) != kIOReturnSuccess) {
        fprintf(stderr, "错误: 无法读取键 %s\n", key);
        return 1;
    }
    print_value(&val);
    printf("\n");
    return 0;
}

static int cmd_info(io_connect_t conn, const char *key)
{
    SMCKeyData_keyInfo_t ki;
    if (SMCReadKeyInfo(conn, key, &ki) != kIOReturnSuccess) {
        fprintf(stderr, "错误: 键 %s 不存在\n", key);
        return 1;
    }
    printf("%s: 类型=%c%c%c%c 大小=%u 属性=0x%02x\n", key,
           (char)(ki.dataType >> 24), (char)(ki.dataType >> 16),
           (char)(ki.dataType >> 8), (char)(ki.dataType),
           ki.dataSize, ki.dataAttributes & 0xff);
    return 0;
}

static int cmd_write(io_connect_t conn, const char *key, double value)
{
    /*
     * 此程序会以 setuid root 安装。写入范围必须严格限制为风扇控制键，
     * 避免任意本地进程借它修改电池、供电等无关 SMC 状态。
     */
    int isTarget = key[0] == 'F' && key[1] >= '0' && key[1] <= '9' &&
                   key[2] == 'T' && key[3] == 'g';
    int isMode = key[0] == 'F' && key[1] >= '0' && key[1] <= '9' &&
                 key[2] == 'M' && key[3] == 'd';
    int isModeLower = key[0] == 'F' && key[1] >= '0' && key[1] <= '9' &&
                      key[2] == 'm' && key[3] == 'd';
    int isTestMode = strcmp(key, "Ftst") == 0;
    int isLegacyMask = strcmp(key, "FS! ") == 0;

    if (!(isTarget || isMode || isModeLower || isTestMode || isLegacyMask)) {
        fprintf(stderr, "错误: 出于安全原因，只允许写入风扇控制键\n");
        return 1;
    }
    if (!isfinite(value)) {
        fprintf(stderr, "错误: 写入值无效\n");
        return 1;
    }
    if (isTarget) {
        double minimum = 0, maximum = 0;
        /* 0 is retained for the existing auto-mode reset path. Every active
         * RPM target must otherwise be inside the hardware-reported range. */
        if (value < 0 || (value != 0 &&
            (read_fan_rpm_limit(conn, key[1] - '0', "Mn", &minimum) != 0 ||
             read_fan_rpm_limit(conn, key[1] - '0', "Mx", &maximum) != 0 ||
             minimum > maximum ||
             value < minimum || value > maximum))) {
            if (minimum > 0 && maximum > 0)
                fprintf(stderr, "错误: 风扇目标转速必须在 %.0f~%.0f RPM 之间\n",
                        minimum, maximum);
            else
                fprintf(stderr, "错误: 无法确认风扇物理转速范围，拒绝写入\n");
            return 1;
        }
    }
    if ((isMode || isModeLower || isTestMode) && value != 0 && value != 1) {
        fprintf(stderr, "错误: 模式值只能是 0 或 1\n");
        return 1;
    }
    if (isLegacyMask && (value < 0 || value > 255 || value != (int)value)) {
        fprintf(stderr, "错误: 旧式风扇掩码必须是 0~255 的整数\n");
        return 1;
    }

    SMCKeyData_keyInfo_t ki;
    if (SMCReadKeyInfo(conn, key, &ki) != kIOReturnSuccess) {
        fprintf(stderr, "错误: 键 %s 不存在\n", key);
        return 1;
    }
    char type[5] = { (char)(ki.dataType >> 24), (char)(ki.dataType >> 16),
                     (char)(ki.dataType >> 8), (char)(ki.dataType), 0 };

    uint8_t data[32];
    uint32_t size = 0;
    if (encode_value(type, value, data, &size) != 0) {
        fprintf(stderr, "错误: 不支持写入类型 %s\n", type);
        return 1;
    }

    if (SMCWriteKey(conn, key, data, size) != kIOReturnSuccess) {
        fprintf(stderr, "错误: 写入 %s 失败(需要 root 权限)\n", key);
        return 1;
    }
    printf("已写入 %s = %.2f\n", key, value);
    return 0;
}

static int cmd_fans(io_connect_t conn)
{
    SMCVal_t val;
    if (SMCReadKey(conn, "FNum", &val) != kIOReturnSuccess) {
        fprintf(stderr, "错误: 无法读取风扇数量\n");
        return 1;
    }
    int num = (uint8_t)val.bytes[0];
    printf("风扇数量: %d\n", num);
    for (int i = 0; i < num; i++) {
        char kAc[5], kMn[5], kMx[5], kTg[5];
        snprintf(kAc, 5, "F%dAc", i);
        snprintf(kMn, 5, "F%dMn", i);
        snprintf(kMx, 5, "F%dMx", i);
        snprintf(kTg, 5, "F%dTg", i);
        float ac = -1, mn = -1, mx = -1, tg = -1;
        SMCVal_t v;
        if (SMCReadKey(conn, kAc, &v) == kIOReturnSuccess)
            ac = (strcmp(v.dataType, "flt ") == 0) ? decode_flt((uint8_t*)v.bytes)
                                                   : decode_fpe2((uint8_t*)v.bytes);
        if (SMCReadKey(conn, kMn, &v) == kIOReturnSuccess)
            mn = (strcmp(v.dataType, "flt ") == 0) ? decode_flt((uint8_t*)v.bytes)
                                                   : decode_fpe2((uint8_t*)v.bytes);
        if (SMCReadKey(conn, kMx, &v) == kIOReturnSuccess)
            mx = (strcmp(v.dataType, "flt ") == 0) ? decode_flt((uint8_t*)v.bytes)
                                                   : decode_fpe2((uint8_t*)v.bytes);
        if (SMCReadKey(conn, kTg, &v) == kIOReturnSuccess)
            tg = (strcmp(v.dataType, "flt ") == 0) ? decode_flt((uint8_t*)v.bytes)
                                                   : decode_fpe2((uint8_t*)v.bytes);
        printf("风扇 %d: 当前=%.0f RPM 最小=%.0f 最大=%.0f 目标=%.0f\n",
               i, ac, mn, mx, tg);
    }
    return 0;
}

int main(int argc, char *argv[])
{
    int isWrite = argc >= 2 && strcmp(argv[1], "-w") == 0;
    if ((argc >= 3 && (strcmp(argv[1], "-r") == 0 ||
                       strcmp(argv[1], "-i") == 0 ||
                       strcmp(argv[1], "-w") == 0)) &&
        strlen(argv[2]) != 4) {
        fprintf(stderr, "错误: SMC 键必须正好是 4 个字符\n");
        return 1;
    }
    if (isWrite && geteuid() != 0) {
        fprintf(stderr, "错误: 写入需要安装 FanControl 控制组件\n");
        return 1;
    }
    /* 读取不需要特权；setuid 安装后也立即永久降权。 */
    if (!isWrite && geteuid() != getuid() && setuid(getuid()) != 0) {
        fprintf(stderr, "错误: 无法降低读取进程权限\n");
        return 1;
    }

    io_connect_t conn;
    if (SMCOpen(&conn) != kIOReturnSuccess)
        return 1;

    int ret = 1;
    if (argc >= 2 && strcmp(argv[1], "-l") == 0) {
        ret = cmd_list(conn);
    } else if (argc >= 2 && strcmp(argv[1], "-f") == 0) {
        ret = cmd_fans(conn);
    } else if (argc >= 3 && strcmp(argv[1], "-r") == 0) {
        ret = cmd_read(conn, argv[2]);
    } else if (argc >= 3 && strcmp(argv[1], "-i") == 0) {
        ret = cmd_info(conn, argv[2]);
    } else if (argc >= 4 && strcmp(argv[1], "-w") == 0) {
        ret = cmd_write(conn, argv[2], atof(argv[3]));
    } else {
        fprintf(stderr,
            "用法:\n"
            "  smc -l              列出所有 SMC 键\n"
            "  smc -r KEY          读取键值\n"
            "  smc -w KEY VALUE    写入键值(需 root)\n"
            "  smc -f              风扇信息汇总\n"
            "  smc -i KEY          键信息\n");
    }

    SMCClose(conn);
    return ret;
}
