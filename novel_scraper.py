"""通过 SOCKS5 代理抓取网页，并把页面中最长的正文块保存为 TXT。"""

from __future__ import annotations

import argparse
import re
from pathlib import Path
from urllib.parse import urlparse

import requests
from bs4 import BeautifulSoup, Tag


DEFAULT_PROXY = "socks5://127.0.0.1:10808"
BLOCK_TAGS = ("article", "main", "section", "div")
REMOVE_TAGS = (
    "script",
    "style",
    "noscript",
    "svg",
    "canvas",
    "iframe",
    "form",
    "nav",
    "header",
    "footer",
    "aside",
)


def normalize_text(element: Tag) -> str:
    """保留自然段，同时清理多余空白。"""
    text = element.get_text("\n", strip=True)
    lines = []
    for line in text.splitlines():
        line = re.sub(r"[ \t\u3000]+", " ", line).strip()
        if line and (not lines or line != lines[-1]):
            lines.append(line)
    return "\n".join(lines)


def extract_longest_text(html: str) -> tuple[str, str]:
    soup = BeautifulSoup(html, "lxml")
    title = soup.title.get_text(" ", strip=True) if soup.title else "novel"

    for tag in soup.find_all(REMOVE_TAGS):
        tag.decompose()

    candidates: list[tuple[Tag, str]] = []
    for element in soup.find_all(BLOCK_TAGS):
        text = normalize_text(element)
        if len(text) >= 100:
            candidates.append((element, text))

    if candidates:
        # 避免外层容器仅仅包住正文时胜出：优先选择几乎含有同样文本的更深层块。
        specific_candidates: list[tuple[Tag, str]] = []
        for element, text in candidates:
            child_lengths = [
                len(normalize_text(child))
                for child in element.find_all(BLOCK_TAGS, recursive=True)
            ]
            if not child_lengths or max(child_lengths) < len(text) * 0.9:
                specific_candidates.append((element, text))

        pool = specific_candidates or candidates
        body = max(pool, key=lambda item: len(item[1]))[1]
    elif soup.body:
        body = normalize_text(soup.body)
    else:
        body = normalize_text(soup)

    if not body:
        raise ValueError("页面中没有提取到可保存的文本")
    return title, body


def safe_filename(title: str, url: str) -> str:
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", title).strip(" ._")
    if not name:
        name = urlparse(url).netloc or "novel"
    return f"{name[:100]}.txt"


def scrape_and_save(
    session: requests.Session,
    url: str,
    output_name: str | None = None,
) -> Path:
    response = session.get(url, timeout=30)
    response.raise_for_status()
    response.encoding = response.apparent_encoding or response.encoding
    title, body = extract_longest_text(response.text)

    output_path = Path(__file__).resolve().parent / (
        output_name or safe_filename(title, url)
    )
    output_path.write_text(body + "\n", encoding="utf-8")
    print(f"已保存：{output_path}")
    print(f"正文长度：{len(body)} 个字符")
    return output_path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url", nargs="?", help="在线小说当前章节的 URL")
    parser.add_argument(
        "--proxy",
        default=DEFAULT_PROXY,
        help=f"SOCKS5 代理地址（默认：{DEFAULT_PROXY}）",
    )
    parser.add_argument(
        "--output",
        help="首次成功抓取的输出文件名；之后使用网页标题",
    )
    args = parser.parse_args()

    session = requests.Session()
    session.proxies.update({"http": args.proxy, "https": args.proxy})
    session.headers.update(
        {
            "User-Agent": (
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
            "AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/126.0 Safari/537.36"
            )
        }
    )

    pending_url = args.url.strip() if args.url else None
    success_count = 0
    print("可连续粘贴小说 URL；直接回车或输入 q、quit、exit 结束。")

    try:
        while True:
            if pending_url is not None:
                url = pending_url
                pending_url = None
            else:
                try:
                    url = input("\n请粘贴在线小说 URL：").strip()
                except EOFError:
                    break

            if not url or url.lower() in {"q", "quit", "exit"}:
                break
            if not url.startswith(("http://", "https://")):
                print("输入无效：URL 必须以 http:// 或 https:// 开头")
                continue

            try:
                output_name = args.output if success_count == 0 else None
                scrape_and_save(session, url, output_name)
                success_count += 1
            except requests.RequestException as exc:
                print(f"抓取失败：{exc}")
            except (OSError, ValueError) as exc:
                print(f"处理失败：{exc}")
    except KeyboardInterrupt:
        print()
    finally:
        session.close()

    print(f"已退出，共成功保存 {success_count} 个页面。")


if __name__ == "__main__":
    main()
