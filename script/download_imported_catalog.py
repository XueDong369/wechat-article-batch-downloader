#!/usr/bin/env python3
"""Queue an app-imported article catalog through the local desktop service.

Only public article links are read from the catalog. Authentication stays in the
running desktop app. Each small batch must finish before the next is submitted.
"""

import argparse
import json
import time
import urllib.parse
import urllib.request
import uuid
from pathlib import Path


API = "http://127.0.0.1:2132"
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def call(path, body=None):
    data = None if body is None else json.dumps(body, ensure_ascii=False).encode()
    request = urllib.request.Request(
        API + path,
        data=data,
        headers={"Content-Type": "application/json"} if data else {},
    )
    with OPENER.open(request, timeout=30) as response:
        result = json.load(response)
    if result.get("code") != 0:
        raise RuntimeError(f"local service rejected {path}: code={result.get('code')}")
    return result["data"]


def safe_name(value):
    text = "".join("_" if char in '/\\:*?"<>|' or ord(char) < 32 else char for char in value)
    return (text.strip(" .") or "公众号")[:70]


def validated_articles(catalog, expected_biz):
    if catalog.get("biz") != expected_biz:
        raise ValueError("catalog account does not match --biz")
    articles = catalog.get("articles", [])
    seen = set()
    for article in articles:
        parts = urllib.parse.urlsplit(article["url"])
        params = dict(urllib.parse.parse_qsl(parts.query))
        if (parts.scheme, parts.netloc, parts.path) != ("https", "mp.weixin.qq.com", "/s"):
            raise ValueError("catalog contains a non-article URL")
        if params.get("__biz") != expected_biz or not all(params.get(k) for k in ("mid", "idx", "sn")):
            raise ValueError("catalog contains an article from another account or an incomplete URL")
        article_id = article["id"]
        if article_id in seen:
            continue
        seen.add(article_id)
        yield article


def batch_status(batch_id):
    for summary in call("/api/desktop/download-summary"):
        if summary.get("batch_id") == batch_id:
            return summary
    return None


def pause_queued(batch_id):
    page = 1
    while True:
        data = call(f"/api/task/list?page={page}&page_size=1000")
        for task in data["list"]:
            labels = ((task.get("meta") or {}).get("req") or {}).get("labels") or {}
            if labels.get("batch_id") == batch_id and task.get("status") in ("wait", "ready"):
                try:
                    call("/api/task/pause", {"id": task["id"]})
                except RuntimeError as error:
                    # A queued task can start between listing and pausing it.
                    if "code=409" not in str(error):
                        raise
        if page * 1000 >= data["total"]:
            return
        page += 1


def resume_waiting(batch_id, limit=3):
    """Nudge local tasks when the downloader has no active worker."""
    resumed = 0
    page = 1
    while resumed < limit:
        data = call(f"/api/task/list?page={page}&page_size=1000")
        for task in data["list"]:
            labels = ((task.get("meta") or {}).get("req") or {}).get("labels") or {}
            if labels.get("batch_id") != batch_id or task.get("status") not in ("wait", "ready"):
                continue
            call("/api/task/resume", {"id": task["id"]})
            resumed += 1
            if resumed >= limit:
                break
        if page * 1000 >= data["total"]:
            break
        page += 1
    return resumed


def batch_errors(batch_id):
    errors = []
    page = 1
    while True:
        data = call(f"/api/task/list?page={page}&page_size=1000")
        for task in data["list"]:
            labels = ((task.get("meta") or {}).get("req") or {}).get("labels") or {}
            if labels.get("batch_id") == batch_id and task.get("error"):
                errors.append(task["error"])
        if page * 1000 >= data["total"]:
            return errors
        page += 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("catalog", type=Path, help="app imports/<hash>.json file")
    parser.add_argument("--biz", required=True, help="expected account __biz")
    parser.add_argument("--batch-size", type=int, default=20)
    parser.add_argument("--start", type=int, default=0, help="zero-based first catalog row to process")
    parser.add_argument("--limit", type=int, default=0, help="0 means entire catalog")
    parser.add_argument("--skip-deleted", action="store_true", help="record and continue past publisher-deleted articles")
    parser.add_argument("--skip-unparsed", action="store_true", help="record one isolated article-page parse failure per batch")
    args = parser.parse_args()
    if not 1 <= args.batch_size <= 50 or args.limit < 0 or args.start < 0:
        parser.error("batch size must be 1..50; start and limit must be nonnegative")
    catalog = json.loads(args.catalog.read_text(encoding="utf-8"))
    articles = list(validated_articles(catalog, args.biz))
    articles = articles[args.start : args.limit or None]
    account = catalog["accountName"]
    print(f"catalog={len(articles)} account={account} batch_size={args.batch_size}", flush=True)
    totals = {"created": 0, "skipped": 0, "failed": 0, "completed": 0, "deleted": 0, "unparsed": 0}
    for start in range(0, len(articles), args.batch_size):
        chunk = articles[start : start + args.batch_size]
        batch_id = "local-safe-" + uuid.uuid4().hex[:16]
        labels = {
            "batch_id": batch_id,
            "batch_total": str(len(chunk)),
            "batch_started_at": str(int(time.time() * 1000)),
            "account_name": account,
            "download_mode": "safe",
        }
        body = [
            {
                "URL": "officialaccount://" + article["url"],
                "Filename": safe_name(article["title"]) + "-" + article["id"] + ".html",
                "Dir": safe_name(account),
                "on_exists": "skip",
                "Extra": labels,
            }
            for article in chunk
        ]
        queued = call("/api/desktop/queue", body)
        for key in ("created", "skipped", "failed"):
            totals[key] += queued[key]
        print(
            f"queued={start + len(chunk)}/{len(articles)} "
            f"created={queued['created']} skipped={queued['skipped']} failed={queued['failed']}",
            flush=True,
        )
        if queued["failed"]:
            pause_queued(batch_id)
            raise RuntimeError("task creation failed; remaining catalog was not queued")
        if not queued["created"]:
            continue
        deadline = time.monotonic() + 900
        reported_kick = False
        while True:
            status = batch_status(batch_id)
            if status:
                if status["failed"] or status["missing"] or status["paused"]:
                    if status["failed"] and not status["missing"] and not status["paused"]:
                        errors = batch_errors(batch_id)
                        deleted = sum("文章已被发布者删除" in error for error in errors)
                        unparsed = sum("cgiDataNew script not found" in error for error in errors)
                        allowed = (
                            len(errors) == status["failed"]
                            and deleted + unparsed == len(errors)
                            and (deleted == 0 or args.skip_deleted)
                            and (unparsed == 0 or args.skip_unparsed)
                            and unparsed <= 1
                        )
                        if allowed:
                            if status["running"] or status["queued"]:
                                if status["running"] == 0 and status["queued"] > 0:
                                    resume_waiting(batch_id)
                                time.sleep(5)
                                continue
                            totals["completed"] += status["completed"]
                            totals["deleted"] += deleted
                            totals["unparsed"] += unparsed
                            print(
                                f"completed={totals['completed']} newly downloaded; "
                                f"publisher_deleted={totals['deleted']} "
                                f"page_unparsed={totals['unparsed']}",
                                flush=True,
                            )
                            break
                    pause_queued(batch_id)
                    raise RuntimeError(
                        f"batch stopped: completed={status['completed']} "
                        f"failed={status['failed']} missing={status['missing']} paused={status['paused']}"
                    )
                if status["completed"] >= queued["created"]:
                    totals["completed"] += status["completed"]
                    print(f"completed={totals['completed']} newly downloaded in this run", flush=True)
                    break
                if status["running"] == 0 and status["queued"] > 0:
                    resumed = resume_waiting(batch_id)
                    if resumed and not reported_kick:
                        print("local queue was idle; resumed waiting tasks", flush=True)
                        reported_kick = True
            if time.monotonic() >= deadline:
                pause_queued(batch_id)
                raise TimeoutError("batch exceeded 15 minutes; queued tasks were paused")
            time.sleep(5)
    print("finished", totals, flush=True)


if __name__ == "__main__":
    main()
