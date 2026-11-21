"""豆仓调用 social-dl（用户自己的下载工具，dl.py / subtitles.py 原样放在旁边）的薄包装。

    python beanpod_social.py <链接> <保存目录>
    环境变量 BEANPOD_COOKIE：豆仓登录窗口里这个平台的登录状态（可以没有）
    环境变量 BEANPOD_WANT_VIDEO=1：要带画面的视频（豆仓要保留画面时），不然小红书只下纯音频流

只用 social-dl 自己写的平台解析器（小红书、抖音、快手、TikTok），把作品的音视频下到保存目录：
- 不走它的 yt-dlp 后备：那条默认去读 Chrome 里的登录状态，豆仓不读浏览器的登录状态。
  解析器拿不到时，豆仓自己再调 yt-dlp，带的是豆仓登录窗口里的登录。
- 不走视频号：豆仓自己做了，用的是在豆仓登录窗口里扫码登录的腾讯元宝。
每一步用一行「BPJSON {...}」报给豆仓，最后一行 type=result 是结果。
"""

import json
import os
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

OWN_PLATFORMS = ("xiaohongshu", "douyin", "kuaishou", "tiktok")


def say(event: dict) -> None:
    sys.stdout.write("BPJSON " + json.dumps(event, ensure_ascii=False) + "\n")
    sys.stdout.flush()


EXTRA_HOSTS = ("www.xiaohongshu.com", "www.rednote.com", "edith.xiaohongshu.com", "xhslink.com",
               "www.douyin.com", "www.iesdouyin.com", "v.douyin.com", "www.kuaishou.com", "v.kuaishou.com")


def use_system_dns() -> None:
    """curl_cffi 自带一套 DNS 解析，实测在用户这台 Mac 上解 www.xiaohongshu.com 只拿到空答案、转去连不通的地址
    （「Failed to connect … after 26 ms」），系统的解析是好的。每次请求前用系统解析出 IPv4 地址，
    通过 CURLOPT_RESOLVE 告诉 curl；跳转常去的几个站也一起放进去。dl.py 本身不用改。"""
    import socket
    from urllib.parse import urlparse

    from curl_cffi import requests as cr
    from curl_cffi.const import CurlOpt

    cache: dict = {}

    def entry(host: str, port: int):
        key = (host, port)
        if key not in cache:
            try:
                ips = sorted({a[4][0] for a in socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_STREAM)})
            except OSError:
                ips = []
            cache[key] = f"{host}:{port}:{','.join(ips)}".encode() if ips else None
        return cache[key]

    # dl.py 用的是 curl_cffi.requests.get/post，它们都走模块里的 request()，这里换掉它
    original = cr.request

    def request(method, url, *args, **kwargs):
        try:
            u = urlparse(url)
            port = u.port or (443 if u.scheme == "https" else 80)
            hosts = {u.hostname or "", *EXTRA_HOSTS} if port == 443 else {u.hostname or ""}
            pins = [e for e in (entry(h, port) for h in hosts if h) if e]
            if pins:
                opts = dict(kwargs.get("curl_options") or {})
                opts[CurlOpt.RESOLVE] = pins
                kwargs["curl_options"] = opts
        except Exception:
            pass
        return original(method, url, *args, **kwargs)

    cr.request = request


def strip_js_collections(text: str) -> str:
    """把 new Map([...]) / new Set([...]) 换成里面的数组；空的 Map 换成 {}。跳过字符串里的括号。"""
    import re

    pattern = re.compile(r"new (Map|Set)\(")
    out, i = [], 0
    while True:
        m = pattern.search(text, i)
        if not m:
            out.append(text[i:])
            break
        out.append(text[i:m.start()])
        j, depth, quote, escaped = m.end(), 1, "", False
        while j < len(text) and depth:
            c = text[j]
            if quote:
                if escaped:
                    escaped = False
                elif c == "\\":
                    escaped = True
                elif c == quote:
                    quote = ""
            elif c in "\"'":
                quote = c
            elif c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            j += 1
        inner = text[m.end():j - 1].strip()
        out.append("{}" if m.group(1) == "Map" and inner in ("", "[]") else (inner or "[]"))
        i = j
    return "".join(out)


def tolerate_js_collections(dl) -> None:
    """小红书页面数据（window.__INITIAL_STATE__）里新出现了 JS 写法 new Map([])，不是 JSON，
    social-dl 的 load_js_object 会整段读不出来、报「未能解析小红书笔记」。读之前先换掉。dl.py 本身不用改。"""
    original = dl.load_js_object

    def load(text, marker):
        if text and ("new Map(" in text or "new Set(" in text):
            text = strip_js_collections(text)
        return original(text, marker)

    dl.load_js_object = load


def prefer_small_audio(dl) -> None:
    """豆仓只要声音，不要原画：小红书视频笔记的 mediaV2 里另有纯音频流（audio_stream，AAC），挑最小的一路先下
    （实测 16 分钟的笔记：原画 101 MB，纯音频 11.8 MB）；没有纯音频流时，挑带声音的码流里最小的一路；
    social-dl 原来的顺序（原画在前）放到最后兜底。"""
    original = dl.XiaohongshuExtractor._video_urls

    def video_urls(self, note):
        rest = original(self, note)
        video = note.get("video") or {}
        first = []
        try:
            v2 = video.get("mediaV2")
            v2 = json.loads(v2) if isinstance(v2, str) else (v2 or {})
            audio = [it for items in (v2.get("audio_stream") or {}).values()
                     for it in (items if isinstance(items, list) else [items])
                     if isinstance(it, dict) and it.get("master_url")]
            for it in sorted(audio, key=lambda it: it.get("size") or float("inf")):
                first += [it["master_url"], *(it.get("backup_urls") or [])]
        except Exception:
            first = []
        if not first:
            stream = ((video.get("media") or {}).get("stream") or {}).values()
            voiced = [it for items in stream if isinstance(items, list) for it in items
                      if isinstance(it, dict) and (it.get("audioBitrate") or it.get("audioCodec"))]
            for it in sorted(voiced, key=lambda it: it.get("size") or float("inf")):
                first += [*([it["masterUrl"]] if it.get("masterUrl") else []), *(it.get("backupUrls") or [])]
        seen, out = set(), []
        for u in [dl.ensure_https(x) for x in first] + list(rest):
            if u and u not in seen:
                seen.add(u)
                out.append(u)
        return out

    dl.XiaohongshuExtractor._video_urls = video_urls


def xhs_resolve(url: str, http) -> str:
    """小红书把海外访问的 xiaohongshu.com 302 到 rednote.com。跨站跳转时手写的 Cookie 头会被丢掉，
    所以先探一次跳转，直接用 rednote 的地址（social-dl 认 rednote.com）。"""
    try:
        from curl_cffi import requests as cr

        r = cr.get(url, headers=http.headers(referer="https://www.xiaohongshu.com/"),
                   allow_redirects=False, timeout=15, impersonate="chrome")
        loc = r.headers.get("location") or ""
        if r.status_code in (301, 302, 303, 307, 308) and "rednote." in loc and "/login" not in loc:
            say({"type": "step", "id": "rednote", "label": "小红书跳到了 rednote.com", "detail": "", "state": "done"})
            return loc
    except Exception:
        pass
    return url


def xhs_login_wall(url: str, http) -> bool:
    """解析失败时看一眼：是不是被带到了登录页（海外访问 rednote 要登录才给看笔记）。"""
    try:
        r = http.get(url, referer="https://www.xiaohongshu.com/")
        final = str(r.url)
        return "/login" in final or "website-login" in final
    except Exception:
        return False


def main() -> int:
    if len(sys.argv) < 3:
        say({"type": "result", "ok": False, "error": "用法：beanpod_social.py <链接> <保存目录>"})
        return 2
    url, out = sys.argv[1], Path(sys.argv[2])

    import dl

    use_system_dns()
    tolerate_js_collections(dl)
    # 豆仓要保留画面时（BEANPOD_WANT_VIDEO=1）照 social-dl 原来的顺序下带画面的；否则只挑声音
    if os.environ.get("BEANPOD_WANT_VIDEO") != "1":
        prefer_small_audio(dl)

    def no_ytdlp(*args, **kwargs):
        raise dl.FetchError("这一步交给密盒助手自己的 yt-dlp")

    dl.ytdlp_download = no_ytdlp

    platform = dl.detect_platform(url)
    if platform not in OWN_PLATFORMS:
        say({"type": "result", "ok": False, "skip": True, "error": f"{platform} 不归 social-dl 的解析器管"})
        return 2

    http = dl.Http(cookie=os.environ.get("BEANPOD_COOKIE", ""))
    if platform == "xiaohongshu":
        url = xhs_resolve(url, http)

    out.mkdir(parents=True, exist_ok=True)
    try:
        reports, failures = dl.parse_and_download(
            url,
            out_dir=out,
            http=http,
            image_format="jpeg",
            info_only=False,
            prefer_ytdlp=False,
            cookies_from_browser="",
            progress=say,
        )
    except dl.FetchError as exc:
        # 全部失败时 social-dl 会抛出来；小红书再看一眼是不是被拦在登录页
        needs = getattr(exc, "needs_login", "") or ""
        if not needs and platform == "xiaohongshu" and xhs_login_wall(url, http):
            needs = "xiaohongshu"
        say({"type": "result", "ok": False, "error": str(exc), "needs_login": needs})
        return 1
    except Exception as exc:  # 解析器里任何意外都别让豆仓卡住
        say({"type": "result", "ok": False, "error": f"{type(exc).__name__}: {exc}"[:300]})
        return 1

    if not reports:
        first = failures[0] if failures else {}
        needs = first.get("needs_login") or ""
        if not needs and platform == "xiaohongshu" and xhs_login_wall(url, http):
            needs = "xiaohongshu"
        say({"type": "result", "ok": False, "error": first.get("error") or "没有拿到作品", "needs_login": needs})
        return 1
    r = reports[0]
    say({
        "type": "result",
        "ok": True,
        "platform": r.get("platform", ""),
        "id": r.get("id", ""),
        "title": r.get("title", ""),
        "author": r.get("author", ""),
        "engine": r.get("engine", ""),
        "files": r.get("files", []),
    })
    return 0


if __name__ == "__main__":
    sys.exit(main())
