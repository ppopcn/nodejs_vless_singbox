#!/usr/bin/env node
/**
 * =================================================================
 * Sing-box 终极双子星脚本（VLESS-WS-TLS + Hysteria 2 混淆版）
 * 专治 LXD 母鸡屏蔽与运营商 UDP QoS 阻断
 * 定时重启：每天北京时间 00:00（24:00）
 * =================================================================
 */
import { execSync, spawn } from "child_process";
import fs from "fs";
import https from "https";
import crypto from "crypto";
import path from "path";
import { fileURLToPath } from "url";

// 获取当前脚本所在目录（ESM 兼容）
const __dirname = path.dirname(fileURLToPath(import.meta.url));

// ================== 【手动设置 UUID 和 密码】==================
const UUID = "fdeeda45-0a8e-4570-bcc6-d68c995f5830";  // VLESS 使用
const PASSWORD = "MyCustomPassword123";               // Hysteria 2 连接密码与混淆密码

// 格式校验
if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(UUID)) {
  console.error("\nUUID 格式错误！");
  process.exit(1);
}
console.log(`使用手动设置的 UUID: ${UUID}`);

// ================== 内置定时器（北京时间 00:00 重启 sing-box 子进程）==================
let currentProc = null; // 保留子进程引用，用于定时重启

function scheduleBeijingTimeMidnight(callback) {
  const now = new Date();
  const beijingNow = new Date(now.toLocaleString("en-US", { timeZone: "Asia/Shanghai" }));
  let target = new Date(beijingNow);
  target.setHours(0, 0, 0, 0);
  if (beijingNow.getTime() >= target.getTime()) target.setDate(target.getDate() + 1);
  const delay = target.getTime() - beijingNow.getTime();
  const hours = (delay / 3600000).toFixed(1);
  console.log(`[定时重启] 距下次北京时间午夜重启还有 ${hours} 小时`);
  setTimeout(() => {
    callback();
    scheduleBeijingTimeMidnight(callback);
  }, delay);
}

const MASQ_DOMAINS = ["www.bing.com"];
const CONFIG_JSON = "config.json";
const CERT_PEM = "cert.pem";
const KEY_PEM = "key.pem";
const LINK_TXT = "proxy_links.txt";
const SINGBOX_BIN = "./sing-box";

const randomSNI = () => MASQ_DOMAINS[Math.floor(Math.random() * MASQ_DOMAINS.length)];
function fileExists(p) { return fs.existsSync(p); }
function execSafe(cmd) { try { return execSync(cmd, { encoding: "utf8", stdio: "pipe" }).trim(); } catch { return ""; } }

// ================== 系统环境检测 ==================
function detectLibc() {
  // 检查是否存在 musl 动态链接器 → Alpine
  try {
    const muslLinks = execSafe("ls /lib/ld-musl-*.so.1 2>/dev/null");
    if (muslLinks) return "musl";
  } catch {}
  // 备用：ldd --version 输出包含 "musl"
  const lddOut = execSafe("ldd --version 2>&1 || true");
  if (/musl/i.test(lddOut)) return "musl";
  return "glibc";
}

function detectInitSystem() {
  if (execSafe("command -v systemctl")) return "systemd";
  if (execSafe("command -v rc-service")) return "openrc";
  return "unknown";
}

const LIBC_TYPE = detectLibc();
const INIT_SYSTEM = detectInitSystem();
console.log(`[环境] libc: ${LIBC_TYPE}, init: ${INIT_SYSTEM}`);

function ensureOpenSSL() {
  if (execSafe("command -v openssl")) return;
  console.log("[依赖] openssl 未安装，正在自动安装...");
  if (execSafe("command -v apt-get")) {
    execSync("apt-get update -qq && apt-get install -y -qq openssl", { stdio: "inherit" });
  } else if (execSafe("command -v yum")) {
    execSync("yum install -y openssl", { stdio: "inherit" });
  } else if (execSafe("command -v apk")) {
    execSync("apk add --no-cache openssl", { stdio: "inherit" });
  } else {
    console.error("[依赖] 无法自动安装 openssl，请手动安装后重试");
    process.exit(1);
  }
  if (!execSafe("command -v openssl")) {
    console.error("[依赖] openssl 安装失败！");
    process.exit(1);
  }
  console.log("[依赖] openssl 安装成功");
}

async function getPublicIP() {
  const sources = ["https://api.ipify.org", "https://ifconfig.me", "https://icanhazip.com"];
  for (const url of sources) {
    try {
      const ip = await new Promise((resolve, reject) => {
        const req = https.get(url, { timeout: 3000 }, (res) => {
          let data = "";
          res.on("data", chunk => data += chunk);
          res.on("end", () => resolve(data.trim()));
        });
        req.on("error", reject);
      });
      if (ip && !/^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|127\.)/.test(ip)) return ip;
    } catch (e) {}
  }
  return "127.0.0.1";
}

async function downloadFile(url, dest) {
  return new Promise((resolve, reject) => {
    const file = fs.createWriteStream(dest);
    https.get(url, (res) => {
      if ([301, 302, 303, 307, 308].includes(res.statusCode)) return resolve(downloadFile(res.headers.location, dest));
      res.pipe(file);
      file.on("finish", () => file.close(resolve));
    }).on("error", reject);
  });
}

function getPorts() {
  const basePort = (process.env.SERVER_PORT && !isNaN(process.env.SERVER_PORT)) ? Number(process.env.SERVER_PORT) : 8989;
  return { vless: basePort, hy2: basePort + 1 };
}

function generateCert(domain) {
  if (fileExists(CERT_PEM) && fileExists(KEY_PEM)) return;
  ensureOpenSSL();
  execSafe(`openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout ${KEY_PEM} -out ${CERT_PEM} -subj "/CN=${domain}" -days 365 -nodes`);
}

async function checkSingBox() {
  if (fileExists(SINGBOX_BIN)) return;
  const SINGBOX_VER = "1.11.1";
  // 根据 libc 类型选择对应二进制：musl → linux-musl-amd64, glibc → linux-amd64
  const suffix = LIBC_TYPE === "musl" ? `linux-musl-amd64` : `linux-amd64`;
  const tarName = `sing-box-${SINGBOX_VER}-${suffix}.tar.gz`;
  const tarUrl = `https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VER}/${tarName}`;
  console.log(`[下载] sing-box v${SINGBOX_VER} (${LIBC_TYPE}): ${tarUrl}`);
  await downloadFile(tarUrl, "sing-box.tar.gz");
  // 通用解压：兼容 GNU tar 和 BusyBox tar（不使用 --wildcards）
  execSafe(`mkdir -p /tmp/_singbox_ext && tar -zxf sing-box.tar.gz -C /tmp/_singbox_ext`);
  // 递归查找 sing-box 二进制文件
  const found = execSafe(`find /tmp/_singbox_ext -name 'sing-box' -type f`);
  if (!found) { console.error("[下载] 解压后未找到 sing-box 二进制文件"); process.exit(1); }
  fs.copyFileSync(found, SINGBOX_BIN);
  fs.chmodSync(SINGBOX_BIN, 0o755);
  try { fs.unlinkSync("sing-box.tar.gz"); } catch {}
  execSafe(`rm -rf /tmp/_singbox_ext`);
  console.log("[下载] sing-box 安装完成");
}

// 生成 VLESS + Hysteria 2 配置
function generateConfig(uuid, password, ports, domain) {
  const config = {
    "log": { "level": "warn", "timestamp": true },
    "inbounds": [
      // 1. VLESS 备份链路 (TCP)
      {
        "type": "vless",
        "tag": "vless-in",
        "listen": "::",
        "listen_port": ports.vless,
        "users": [{ "uuid": uuid, "name": "vless-user" }],
        "tls": { "enabled": true, "server_name": domain, "certificate_path": CERT_PEM, "key_path": KEY_PEM },
        "transport": { "type": "ws", "path": "/", "early_data_header_name": "Sec-WebSocket-Protocol" }
      },
      // 2. Hysteria 2 冲浪链路 (UDP + 混淆)
      {
        "type": "hysteria2",
        "tag": "hy2-in",
        "listen": "::",
        "listen_port": ports.hy2,
        "users": [{ "password": password }],
        "tls": { "enabled": true, "server_name": domain, "certificate_path": CERT_PEM, "key_path": KEY_PEM },
        "obfs": {
          "type": "salamander", // 使用 salamander 混淆算法，将 UDP 包装成无可名状的随机流，穿透 DPI
          "password": password
        }
      }
    ],
    "outbounds": [{ "type": "direct", "tag": "direct" }]
  };
  fs.writeFileSync(CONFIG_JSON, JSON.stringify(config, null, 2));
}

function generateLinks(uuid, password, ip, ports, domain) {
  const vlessLink = `vless://${uuid}@${ip}:${ports.vless}?security=tls&encryption=none&type=ws&path=%2F&sni=${domain}&allowInsecure=1#VLESS-WS-${ip}`;
  
  // Hysteria 2 标准规范链接
  const hy2Link = `hysteria2://${password}@${ip}:${ports.hy2}?insecure=1&sni=${domain}&obfs=salamander&obfs-password=${password}#HY2-${ip}`;
  
  const output = [
    "==================== PROXY LINKS ====================",
    `【VLESS-WS-TLS 链接 (端口: ${ports.vless} / TCP)】:`,
    vlessLink,
    "",
    `【Hysteria 2 混淆加速链接 (端口: ${ports.hy2} / UDP)】:`,
    hy2Link,
    "\n注：若 Hysteria 2 仍因母鸡物理断绝 UDP 导致不通，VLESS 节点将作为坚实后盾保底连接。",
    "====================================================="
  ].join("\n");
  fs.writeFileSync(LINK_TXT, output);
  console.log("\n" + output + "\n");
}

// ================== 服务管理（systemd / OpenRC 双支持）==================
const SERVICE_NAME = "vless-singbox";
const SERVICE_FILE_SYSTEMD = `/etc/systemd/system/${SERVICE_NAME}.service`;
const SERVICE_FILE_OPENRC = `/etc/init.d/${SERVICE_NAME}`;

function isRunningAsService() {
  return process.env.VLESS_SERVICE_MODE === "1";
}

function generateSystemdUnit(nodePath) {
  const content = `[Unit]
Description=Vless Singbox Node Service
After=network.target

[Service]
User=root
WorkingDirectory=${__dirname}
Environment=VLESS_SERVICE_MODE=1
ExecStart=${nodePath} index.js
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
`;
  fs.writeFileSync(SERVICE_FILE_SYSTEMD, content);
  console.log(`[服务] 已创建 systemd 服务文件: ${SERVICE_FILE_SYSTEMD}`);

  execSync("systemctl daemon-reload", { stdio: "inherit" });
  execSync(`systemctl enable ${SERVICE_NAME}`, { stdio: "inherit" });
  execSafe(`systemctl stop ${SERVICE_NAME}`);
  execSync(`systemctl start ${SERVICE_NAME}`, { stdio: "inherit" });

  console.log(`
========== 服务管理命令 ==========
  查看状态: systemctl status ${SERVICE_NAME}
  停止服务: systemctl stop ${SERVICE_NAME}
  重启服务: systemctl restart ${SERVICE_NAME}
  查看日志: journalctl -u ${SERVICE_NAME} -f
==================================
`);
}

function generateOpenRCScript(nodePath) {
  const content = `#!/sbin/openrc-run

name="${SERVICE_NAME}"
description="Vless Singbox Node Service"
command="${nodePath}"
command_args="index.js"
command_user="root"
command_background="yes"
directory="${__dirname}"
export VLESS_SERVICE_MODE=1
pidfile="/run/\${RC_SVCNAME}.pid"

depend() {
    need net
    after net
}
`;
  fs.writeFileSync(SERVICE_FILE_OPENRC, content, { mode: 0o755 });
  console.log(`[服务] 已创建 OpenRC 服务脚本: ${SERVICE_FILE_OPENRC}`);

  execSync(`chmod +x ${SERVICE_FILE_OPENRC}`, { stdio: "inherit" });
  execSync(`rc-update add ${SERVICE_NAME} default`, { stdio: "inherit" });
  execSafe(`rc-service ${SERVICE_NAME} stop`);
  execSync(`rc-service ${SERVICE_NAME} start`, { stdio: "inherit" });

  console.log(`
========== 服务管理命令 ==========
  查看状态: rc-service ${SERVICE_NAME} status
  停止服务: rc-service ${SERVICE_NAME} stop
  重启服务: rc-service ${SERVICE_NAME} restart
  查看日志: tail -f /var/log/messages | grep ${SERVICE_NAME}
==================================
`);
}

function installService() {
  const nodePath = process.execPath; // 自动检测 node 二进制路径

  if (INIT_SYSTEM === "systemd") {
    generateSystemdUnit(nodePath);
    return true;
  } else if (INIT_SYSTEM === "openrc") {
    generateOpenRCScript(nodePath);
    return true;
  } else {
    console.error("[服务] 未检测到支持的 init 系统（需要 systemd 或 OpenRC）");
    console.error("[服务] 将以守护循环方式直接运行（无服务管理）...");
    scheduleBeijingTimeMidnight(() => {
      console.log("[定时重启] 北京时间午夜，正在重启 sing-box...");
      if (currentProc) currentProc.kill("SIGTERM");
    });
    runLoop();
    return false; // 不退出，直接在前台运行
  }
}

function runLoop() {
  const loop = () => {
    const proc = spawn(SINGBOX_BIN, ["run", "-c", CONFIG_JSON], { stdio: "inherit" });
    currentProc = proc;
    proc.on("exit", (code) => {
      currentProc = null;
      console.log(`[sing-box] 进程退出 (code: ${code})，5 秒后重启...`);
      setTimeout(loop, 5000);
    });
  };
  loop();
}

async function main() {
  const ports = getPorts();
  const domain = randomSNI();
  generateCert(domain);
  await checkSingBox();
  generateConfig(UUID, PASSWORD, ports, domain);
  const ip = await getPublicIP();
  generateLinks(UUID, PASSWORD, ip, ports, domain);

  if (isRunningAsService()) {
    // 由 systemd 启动：直接运行代理循环
    console.log("[服务模式] 由 systemd 管理，启动 sing-box 代理...");
    scheduleBeijingTimeMidnight(() => {
      console.log("[定时重启] 北京时间午夜，正在重启 sing-box...");
      if (currentProc) currentProc.kill("SIGTERM");
    });
    runLoop();
  } else {
    // 手动运行：安装并启动服务，然后退出
    console.log(`[手动模式] 正在安装为 ${INIT_SYSTEM} 服务...`);
    const handled = installService();
    if (handled) {
      console.log("[完成] 服务已启动，当前脚本可以安全关闭。");
      process.exit(0);
    }
    // handled=false 说明没有 init 系统，installService 已回退到前台运行，不退出
  }
}

main().catch((err) => console.error("Error:", err));