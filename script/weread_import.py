#!/usr/bin/env python3
"""Resolve a WeRead book ID or import manually captured article-list pages.

This tool never makes network requests. Imported output contains only public
article metadata; raw responses and account credentials stay in their inputs.
"""

import argparse
import base64
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import re
import sys
from urllib.parse import unquote


BOOK_ID = re.compile(r"MP_WXS_[0-9]+\Z")
ORIGINAL_ID = re.compile(r"[A-Za-z0-9_-]+\Z")
BIZ_IN_URL = re.compile(r"(?:[?&]|\b)__biz=([A-Za-z0-9+/%=]+)")
SHANGHAI = timezone(timedelta(hours=8))


def resolve_book_id(value):
    value = value.strip()
    if BOOK_ID.fullmatch(value):
        return value
    match = BIZ_IN_URL.search(value)
    biz = unquote(match.group(1)) if match else value
    try:
        decoded = base64.b64decode(biz + "=" * (-len(biz) % 4), validate=True)
        number = decoded.decode("ascii")
    except (ValueError, UnicodeError) as exc:
        raise ValueError("输入不是有效的 __biz 或 MP_WXS_ bookId") from exc
    if not number.isdecimal() or not number.isascii():
        raise ValueError("__biz 解码结果不是数字账号标识")
    return "MP_WXS_" + number


def escape_controls_inside_strings(source):
    """Repair control characters inserted by copied response text, in memory."""
    output = []
    in_string = False
    escaped = False
    repaired = 0
    for char in source:
        if in_string:
            if escaped:
                output.append(char)
                escaped = False
                continue
            if char == "\\":
                output.append(char)
                escaped = True
                continue
            if char == '"':
                in_string = False
                output.append(char)
                continue
            if ord(char) < 32:
                output.append(json.dumps(char)[1:-1])
                repaired += 1
                continue
        elif char == '"':
            in_string = True
        output.append(char)
    return "".join(output), repaired


def load_response(path):
    source = Path(path).read_text(encoding="utf-8")
    try:
        return json.loads(source), 0
    except json.JSONDecodeError:
        repaired_source, count = escape_controls_inside_strings(source)
        if not count:
            raise
        return json.loads(repaired_source), count


def import_pages(account, book_id, page_specs):
    if not account.strip() or not BOOK_ID.fullmatch(book_id):
        raise ValueError("需要准确的公众号名称与 MP_WXS_ bookId")
    articles = []
    pages = []
    seen = set()
    previous_offset = -1
    for offset, path in page_specs:
        if not isinstance(offset, int) or offset < 0 or offset <= previous_offset:
            raise ValueError("页面 offset 必须是非负且严格递增的整数")
        previous_offset = offset
        response, repaired = load_response(path)
        if not isinstance(response, dict):
            raise ValueError(f"{path}: 顶层不是对象")
        if response.get("errCode") not in (None, 0):
            raise ValueError(f"{path}: 业务错误 errCode={response['errCode']}")
        groups = response.get("reviews")
        if not isinstance(groups, list):
            raise ValueError(f"{path}: 缺少 reviews 数组，不能当作空页")
        page = {
            "requested_offset": offset,
            "group_count": len(groups),
            "article_count": 0,
            "new_link_count": 0,
            "duplicate_link_count": 0,
            "missing_link_count": 0,
            "repaired_control_characters": repaired,
            "next_offset_candidate": offset + len(groups),
        }
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("subReviews"), list):
                raise ValueError(f"{path}: 群发记录缺少 subReviews")
            children = group["subReviews"]
            if group.get("subCount") != len(children):
                raise ValueError(f"{path}: subCount 与实际子文章数不符")
            timestamp = group.get("createTime")
            if not isinstance(timestamp, int) or timestamp <= 0:
                raise ValueError(f"{path}: 群发记录缺少有效时间")
            published = datetime.fromtimestamp(timestamp, SHANGHAI).isoformat()
            for child in children:
                review = child.get("review") if isinstance(child, dict) else None
                info = review.get("mpInfo") if isinstance(review, dict) else None
                if not isinstance(info, dict):
                    raise ValueError(f"{path}: 子文章缺少 mpInfo")
                if review.get("belongBookId") != book_id or info.get("mp_name") != account:
                    raise ValueError(f"{path}: 子文章的公众号标识与目标不符")
                title = info.get("title")
                if not isinstance(title, str) or not title.strip():
                    raise ValueError(f"{path}: 子文章缺少标题")
                page["article_count"] += 1
                original = info.get("originalId")
                original = original.replace("~", "_") if isinstance(original, str) else ""
                if not ORIGINAL_ID.fullmatch(original):
                    page["missing_link_count"] += 1
                    continue
                if original in seen:
                    page["duplicate_link_count"] += 1
                    continue
                seen.add(original)
                page["new_link_count"] += 1
                articles.append({
                    "title": title.strip(),
                    "published_at": published,
                    "original_url": "https://mp.weixin.qq.com/s/" + original,
                })
        pages.append(page)
    return {
        "account": account,
        "book_id": book_id,
        "scope": "仅包含所导入页面；原文链接由 originalId 构造，未逐篇打开验证",
        "group_count": sum(page["group_count"] for page in pages),
        "article_count": len(articles),
        "pages": pages,
        "articles": articles,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    resolve = commands.add_parser("resolve", help="离线从 __biz、文章长链接或本机账号记录推导 bookId")
    source = resolve.add_mutually_exclusive_group(required=True)
    source.add_argument("--biz-or-url")
    source.add_argument("--account-file", type=Path)
    resolve.add_argument("--name", help="使用 --account-file 时需提供准确昵称")
    importer = commands.add_parser("import", help="导入手动复制的 /web/mp/articles 响应")
    importer.add_argument("--account", required=True)
    importer.add_argument("--book-id", required=True)
    importer.add_argument("--page", action="append", required=True, metavar="OFFSET:FILE")
    importer.add_argument("--out", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "resolve":
            value = args.biz_or_url
            if args.account_file:
                if not args.name:
                    raise ValueError("--account-file 需要 --name")
                accounts = json.loads(args.account_file.read_text(encoding="utf-8"))
                if not isinstance(accounts, dict):
                    raise ValueError("账号文件顶层不是对象")
                matches = [item for item in accounts.values()
                           if isinstance(item, dict) and item.get("nickname") == args.name]
                if len(matches) != 1:
                    raise ValueError(f"账号匹配数量为 {len(matches)}，未输出其他记录")
                value = matches[0].get("biz", "")
            print(resolve_book_id(value))
            return 0
        pages = []
        for item in args.page:
            raw_offset, separator, raw_path = item.partition(":")
            if not separator or not raw_offset.isdecimal() or not raw_path:
                raise ValueError("--page 格式应为 OFFSET:FILE")
            pages.append((int(raw_offset), Path(raw_path)))
        result = import_pages(args.account, args.book_id, pages)
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"已保存 {result['article_count']} 条不重复原文链接；页数 {len(pages)}；文件 {args.out}")
        return 0
    except (OSError, ValueError, json.JSONDecodeError, TypeError) as exc:
        print(f"导入失败：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
