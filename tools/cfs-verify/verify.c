// cfs-verify —— 校验字体工具箱插件包的 Ed25519 签名（标准 Ed25519 / SHA-512）
//
// 用法：cfs-verify MANIFEST.sha256 <base64签名> <公钥hex>
// 退出码：0 通过，1 失败
//
// 依赖 TweetNaCl（public domain），编译时一起链接。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "tweetnacl.h"

// TweetNaCl 的签名接口需要它，但验签路径不会调用
void randombytes(unsigned char *p, unsigned long long n) {
    for (unsigned long long i = 0; i < n; i++) p[i] = 0;
}

static int b64val(int c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

static int b64decode(const char *in, uint8_t *out, size_t outsz) {
    size_t o = 0;
    int quad[4], qn = 0;
    for (const char *p = in; *p; p++) {
        if (*p == '=' || *p == '\n' || *p == '\r' || *p == ' ') continue;
        int v = b64val((unsigned char)*p);
        if (v < 0) return -1;
        quad[qn++] = v;
        if (qn == 4) {
            if (o + 3 > outsz) return -1;
            out[o++] = (uint8_t)((quad[0] << 2) | (quad[1] >> 4));
            out[o++] = (uint8_t)(((quad[1] & 15) << 4) | (quad[2] >> 2));
            out[o++] = (uint8_t)(((quad[2] & 3) << 6) | quad[3]);
            qn = 0;
        }
    }
    // 处理结尾不足 4 个字符的情况（base64 的 = 填充被跳过）
    if (qn == 2) {
        if (o + 1 > outsz) return -1;
        out[o++] = (uint8_t)((quad[0] << 2) | (quad[1] >> 4));
    } else if (qn == 3) {
        if (o + 2 > outsz) return -1;
        out[o++] = (uint8_t)((quad[0] << 2) | (quad[1] >> 4));
        out[o++] = (uint8_t)(((quad[1] & 15) << 4) | (quad[2] >> 2));
    } else if (qn == 1) {
        return -1;
    }
    return (int)o;
}

static int hexdecode(const char *in, uint8_t *out, size_t outsz) {
    size_t n = strlen(in);
    if (n % 2 || n / 2 > outsz) return -1;
    for (size_t i = 0; i < n / 2; i++) {
        unsigned int v;
        if (sscanf(in + i * 2, "%2x", &v) != 1) return -1;
        out[i] = (uint8_t)v;
    }
    return (int)(n / 2);
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: cfs-verify MANIFEST.sha256 <sig-base64> <pubkey-hex>\n");
        return 2;
    }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 2; }
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (len < 0 || len > 8 * 1024 * 1024) { fclose(f); fprintf(stderr, "manifest too big\n"); return 2; }
    uint8_t *msg = malloc((size_t)len ? (size_t)len : 1);
    if (!msg) { fclose(f); return 2; }
    if (len && fread(msg, 1, (size_t)len, f) != (size_t)len) { fclose(f); free(msg); return 2; }
    fclose(f);

    uint8_t sig[64], pub[32];
    if (b64decode(argv[2], sig, sizeof sig) != 64) { fprintf(stderr, "bad signature\n"); free(msg); return 2; }
    if (hexdecode(argv[3], pub, sizeof pub) != 32) { fprintf(stderr, "bad public key\n"); free(msg); return 2; }

    // TweetNaCl 的 crypto_sign_open 期望 sig || message
    unsigned long long smlen = 64 + (unsigned long long)len;
    unsigned char *sm = malloc(smlen ? smlen : 1);
    unsigned char *out = malloc(smlen ? smlen : 1);
    if (!sm || !out) { free(sm); free(out); free(msg); return 2; }
    memcpy(sm, sig, 64);
    if (len) memcpy(sm + 64, msg, (size_t)len);

    unsigned long long outlen = 0;
    int rc = crypto_sign_open(out, &outlen, sm, smlen, pub);
    int ok = (rc == 0 && outlen == (unsigned long long)len &&
              (len == 0 || memcmp(out, msg, (size_t)len) == 0));
    free(sm); free(out); free(msg);
    if (!ok) { fprintf(stderr, "signature mismatch\n"); return 1; }
    return 0;
}
