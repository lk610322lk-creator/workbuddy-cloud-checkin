#!/usr/bin/env node
/**
 * WorkBuddy 每日签到 - 新版加密登录态解密助手（v5.4+ $wbEncrypted 格式）
 *
 * 背景：WorkBuddy 桌面端升级后，%LOCALAPPDATA%\CodeBuddyExtension\Data\Public\auth\
 * workbuddy-desktop.info 中的 auth.accessToken 不再是明文字符串，而是
 * {$wbEncrypted:1, envelope:"<base64>"} 加密包裹（AES-256-GCM，sym-v1 field 信封）。
 * 静态密钥由定制版 Electron 的内置绑定 workbuddyStorage.loggerGet() 提供，
 * 仅在 WorkBuddy.exe 自身的进程内可取。
 *
 * 运行方式（由 decrypt-token.js 自动调用，也可手动验证）：
 *   ELECTRON_RUN_AS_NODE=1 "<WorkBuddy.exe 路径>" decrypt-atrest.js
 *   （ELECTRON_RUN_AS_NODE 下 require('electron') 不可用，但
 *    process._linkedBinding('electron_browser_workbuddy_storage') 仍已注册）
 *
 * 安全警示：
 *   - 解出的 accessToken 等同账号密码，仅通过 stdout 管道输出给调用方立即消费；
 *     切勿写入文件、日志或终端回显。
 *   - 密钥派生与解密全部在内存完成，不产生任何中间文件。
 *
 * 输出（与 decrypt-token.js 契约一致）：
 *   DECRYPT_RESULT:<accessToken>
 *   ACCOUNT_UID:<account.uid>
 *   AUTH_DOMAIN:<auth.domain>
 *   ENTERPRISE_ID:<account.enterpriseId>
 *   失败时输出 DECRYPT_RESULT:ERR ... 并以非零码退出。
 */
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");

function fail(msg) {
  process.stdout.write("DECRYPT_RESULT:ERR " + msg + "\n");
  process.exit(2);
}

// ── 1. 静态钥：仅在 WorkBuddy.exe（含定制绑定）内可取 ─────────
let key = null;
let keyId = null;
try {
  const binding = process._linkedBinding("electron_browser_workbuddy_storage");
  const payload = JSON.parse(binding.loggerGet());
  // 与客户端 key-normalize 逻辑一致：key = sha256(atRestSecretKey utf8)，keyId = sha256(key) 前 16 hex
  key = crypto.createHash("sha256").update(payload.atRestSecretKey, "utf8").digest();
  keyId = crypto.createHash("sha256").update(key).digest("hex").slice(0, 16);
} catch (e) {
  fail("静态钥不可取（须以 ELECTRON_RUN_AS_NODE=1 用 WorkBuddy.exe 运行本脚本）: " + e.message.slice(0, 120));
}

// ── 2. 读取登录态文件（LOCALAPPDATA 优先，APPDATA 回退） ──────
function authFileCandidates() {
  const rel = path.join("CodeBuddyExtension", "Data", "Public", "auth", "workbuddy-desktop.info");
  const out = [];
  if (process.env.LOCALAPPDATA) out.push(path.join(process.env.LOCALAPPDATA, rel));
  if (process.env.APPDATA) out.push(path.join(process.env.APPDATA, rel));
  out.push(path.join(os.homedir(), "AppData", "Local", rel));
  return out;
}

let info = null;
for (const f of authFileCandidates()) {
  if (!fs.existsSync(f)) continue;
  try {
    info = JSON.parse(fs.readFileSync(f, "utf8"));
    break;
  } catch (e) { /* 下一个候选 */ }
}
if (!info || !info.auth) fail("未找到可解析的 WorkBuddy 登录态文件");

// ── 3. 解密 accessToken（sym-v1 field 信封，AES-256-GCM） ────
const acc = info.auth.accessToken;
let token = null;
if (typeof acc === "string") {
  token = acc; // 未升级的明文格式，直接可用
} else if (acc && acc.$wbEncrypted === 1 && typeof acc.envelope === "string" && !acc.scheme) {
  try {
    const env = JSON.parse(Buffer.from(acc.envelope, "base64").toString("utf8"));
    if (env.keyId !== keyId) fail("keyId 不匹配（密钥轮换？）: " + env.keyId + " vs " + keyId);
    // AAD 构造还原自客户端 at-rest-crypto buildAuthenticatedContextAad(sym-v1)：
    // ["WB-AAD\0", 0x01, LP("WBEV1"), LP("sym-v1"), u32(suite), LP(keyId), 0x02(field), optU64(undefined)=00, final(undefined)=00]
    const lp = (s) => { const b = Buffer.from(s, "utf8"); const l = Buffer.alloc(4); l.writeUInt32BE(b.length); return Buffer.concat([l, b]); };
    const u32 = (v) => { const b = Buffer.alloc(4); b.writeUInt32BE(v); return b; };
    const aad = Buffer.concat([
      Buffer.from("WB-AAD\0", "ascii"),
      Buffer.from([1]),
      lp("WBEV1"),
      lp("sym-v1"),
      u32(env.suite),
      lp(env.keyId),
      Buffer.from([2]), // FRAMING_CODE.field
      Buffer.from([0]), // encodeOptionalUint64(undefined)
      Buffer.from([0]), // final === undefined
    ]);
    const d = crypto.createDecipheriv("aes-256-gcm", key, Buffer.from(env.nonce, "base64"), { authTagLength: 16 });
    d.setAAD(aad);
    d.setAuthTag(Buffer.from(env.authTag, "base64"));
    const plain = Buffer.concat([d.update(Buffer.from(env.ciphertext, "base64")), d.final()]).toString("utf8");
    let tok = plain;
    try {
      const j = JSON.parse(plain);
      if (typeof j === "string") tok = j;
      else if (j && j.auth && j.auth.accessToken) tok = j.auth.accessToken;
    } catch (e) { /* 明文即 token 字符串 */ }
    if (typeof tok !== "string" || !tok) fail("解密结果不是 token 字符串");
    token = tok;
  } catch (e) {
    fail("信封解密失败: " + e.message.slice(0, 120));
  }
} else {
  fail("未知的 accessToken 格式");
}

// ── 4. 按契约输出（含账号字段，供拼装鉴权头） ────────────────
const acct = info.account || {};
const authObj = info.auth || {};
const uid = acct.uid != null ? String(acct.uid) : "";
const domain = authObj.domain != null ? String(authObj.domain) : "";
const eid = acct.enterpriseId != null ? String(acct.enterpriseId) : "";
process.stdout.write(
  "DECRYPT_RESULT:" + token + "\n" +
  "ACCOUNT_UID:" + uid + "\n" +
  "AUTH_DOMAIN:" + domain + "\n" +
  "ENTERPRISE_ID:" + eid + "\n"
);
