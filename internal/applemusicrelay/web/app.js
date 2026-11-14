/* No password inputs, analytics, console logging, storage of MUT, or tokens in URLs. */
"use strict";
const status = document.getElementById("status");
const connect = document.getElementById("connect");
const cancel = document.getElementById("cancel");
const back = document.getElementById("return");
const revoke = location.pathname === "/disconnect";
const fragment = location.hash.slice(1).split(".");
history.replaceState(null, "", location.pathname);
let music;
let cancelled = false;
const messages = {
  expired_flow: "连接已过期或已取消。请返回 App 重新连接。",
  developer_unavailable: "开发者服务配置不可用，请联系服务维护者检查 Media ID、密钥和域名。",
  music_access_denied: "Apple 未允许读取音乐资料。请检查授权、账号的音乐资料库及服务资格，然后重新连接。",
  apple_rate_limited: "Apple 请求过多，请稍后重试。",
  apple_network: "授权服务暂时无法连接 Apple，请稍后重新连接。"
};
async function json(path, body) {
  const response = await fetch(path, {method: body ? "POST" : "GET", credentials: "same-origin", cache: "no-store",
    headers: body ? {"Content-Type":"application/json"} : {}, body: body ? JSON.stringify(body) : undefined});
  const value = await response.json();
  if (!response.ok) throw new Error(messages[value.error] || "服务请求失败，请返回 App 重新连接。");
  return value;
}
const loaded = new Promise(resolve => {
  if (window.MusicKit) resolve();
  else document.addEventListener("musickitloaded", resolve, {once:true});
});
async function start() {
  if (location.pathname === "/apple-music/return") {
    status.textContent = "若没有自动打开 App，请从主屏幕返回 MusicDL 后重新连接，并检查 Universal Links 配置。";
    return;
  }
  if (!revoke) {
    if (fragment.length !== 2 || !fragment.every(v => /^[A-Za-z0-9_-]{43}$/.test(v))) throw new Error(messages.expired_flow);
    await json("/v1/browser/start", {id:fragment[0],secret:fragment[1]});
  }
  const config = await json("/v1/web-config");
  await Promise.race([loaded, new Promise((_,reject) => setTimeout(() => reject(new Error("Apple MusicKit 加载超时。请检查网络后从 App 重试。")),20000))]);
  await MusicKit.configure({developerToken:config.developerToken, app:{name:"MusicDL",build:"1"}});
  music = MusicKit.getInstance();
  status.textContent = revoke ? "此操作在当前浏览器撤销此网站的 Apple Music 授权，不会退出 Apple 账号。" : "请点击下方按钮，在 Apple 官方页面登录并同意音乐资料访问。";
  connect.textContent = revoke ? "撤销此网站的 Apple Music 授权" : "在 Apple 官方页面继续";
  connect.disabled = false;
  cancel.disabled = revoke;
}
connect.addEventListener("click", async () => {
  connect.disabled = true;
  try {
    if (revoke) {
      await music.unauthorize();
      status.textContent = "已请求撤销当前浏览器的网站授权。App 的本机连接请在设置中断开。";
      return;
    }
    status.textContent = "请在 Apple 官方页面完成授权…";
    // Invoked directly from the user gesture: authorize may open a popup.
    const token = await music.authorize();
    if (cancelled) return;
    if (typeof token !== "string" || !token) throw new Error("Apple 没有返回音乐访问授权，请重试。");
    status.textContent = "正在验证实际资料库访问能力…";
    const value = await json("/v1/browser/complete", {token});
    if (cancelled) return;
    const callback = new URL(value.callback);
    const custom = callback.protocol === "com.guohuiyuan.musicdl.apple-login:" && callback.hostname === "callback" && callback.pathname === "";
    const universal = callback.origin === location.origin && callback.pathname === "/apple-music/return";
    if (!custom && !universal) throw new Error("返回地址不符合安全配置，请返回 App 重新连接。");
    back.href = callback.href; back.hidden = false;
    cancel.disabled = true;
    status.textContent = "Apple 接口已验证。请返回 App 完成安全校验；若未自动返回，请点击下方按钮。";
    // Safari may require the visible link to be tapped. Never promise auto-return.
    if (custom) location.assign(callback.href);
  } catch (error) {
    // Never show raw Apple errors: they can contain credentials/request URLs.
    status.textContent = error instanceof Error && Object.values(messages).includes(error.message) ? error.message : "授权未完成，可能已取消或 Apple 拒绝访问。请返回 App 重试；若反复失败，请检查网络和开发者服务配置。";
    connect.disabled = cancelled;
  }
});
cancel.addEventListener("click", async () => {
  cancelled = true; connect.disabled = true; cancel.disabled = true;
  try {
    await fetch("/v1/browser/cancel", {method:"POST",credentials:"same-origin"});
    status.textContent = "本页已取消连接。请返回 MusicDL 点击取消授权。";
  } catch { status.textContent = "本页已停止连接。请返回 MusicDL 点击取消授权；未完成请求会自动到期。"; }
});
start().catch(error => { status.textContent = error.message; });
