# 微信读书列表离线导入（开发者工具）

`script/weread_import.py` 用于核查手动复制的 `/web/mp/articles` 响应，并生成只含标题、发布时间、微信原文链接的部分清单。它**不联网**、不读取浏览器 Cookie、不启动桌面应用，也不会把结果直接写入应用数据库。它不是微信读书未收录公众号的通用解法。

## 从已有账号记录推导 `bookId`

微信读书公众号 `bookId` 可由该号文章的 `__biz` 解码得到。输入必须是 `MP_WXS_...`、`__biz` 本身，或包含 `__biz` 的文章长链接；只有 `/s/<短码>` 的短链若页面不提供 `__biz`，不能凭空推导。

```bash
python3 script/weread_import.py resolve --biz-or-url 'https://mp.weixin.qq.com/s?__biz=...&mid=...'
```

已由本应用识别过的账号，可以在本机记录中按准确昵称只读查找。命令只输出推导出的 `bookId`，不输出其他账号和凭证：

```bash
python3 script/weread_import.py resolve \
  --account-file "$HOME/Library/Application Support/MPArticleDownloader/mp.json" \
  --name '罕见病信息网'
```

在本机已验证，上述目标号的 `__biz` 推导结果与微信读书实际请求里的 `MP_WXS_3541883450` 一致。这只能解决标识定位；目标号是否被微信读书收录，仍需实际响应证明。

## 导入一页或多页响应

在已登录阅读页的开发者工具中，只复制 `/web/mp/articles` 请求的 **Response**，分别保存为本机文本文件。不要使用“Copy as cURL”、HAR、请求头或 Cookie。每个 `--page` 的数字必须是该次请求真实使用的 `offset`。

```bash
python3 script/weread_import.py import \
  --account '罕见病信息网' \
  --book-id MP_WXS_3541883450 \
  --page '0:/path/to/first-response.txt' \
  --page '19:/path/to/second-response.txt' \
  --out '/path/to/partial-links.json'
```

工具检查业务错误、`reviews → subReviews`、`subCount`、账号名和 `bookId`，按 `originalId` 去重，遇到复制时混入字符串内的原始换行会在内存中修复。输出不包含 `userVid`、正文、Cookie 或其他原始响应字段。缺少原文标识的条目会计数，但不会生成猜测链接。

`next_offset_candidate` 仅按“本次请求 offset + 实际 `reviews.length`”计算。列表在翻页期间若有新文章插入，后页可能与前页重叠；本机一次阅读目录实测从 19 跳到 39 条时，第二段请求为 `offset=19`，边界处出现同标题、同时间的记录。必须使用实际请求 offset 和文章标识去重，不能凭 offset 或空页断定绝对全量。

原文链接由 `originalId` 构造，仍需另行验证访问与正文。官方公众号平台 API 仅适用于相应授权账号；微信读书以外的其他来源应单独记录来源与覆盖率，不能混称为微信历史全集。

## 阅读页目录与逐篇元数据

同一阅读页的目录向下滚动可继续显示较早的群发标题。目录本身没有原文标识，因此标题清单只能作为发现记录；不能据此生成微信原文 URL。本机一次连续滚动得到 460 组、777 个可见文章条目，最早显示到 2025-07-08，底部加载标记持续存在，不能把停顿判成全部历史的终点。

逐篇在页面中打开时，部分文章内嵌正文的公开 `og:title` 与 `og:url` 可用于核对文章归属并取得长链接。保存时只保留 `__biz`、`mid`、`idx`、`sn` 四个公开文章标识，核对标题和目标号的 `__biz`；若页面提示“根据作者隐私设置，无法查看该内容”，应记录为受限，不猜测链接。逐篇打开比直接导入列表响应慢，适合作为响应不可得时的补充路径。当前实践的可见目录、已核对链接及受限条目分别保存在工作区 `outputs` 中；这些文件均是部分结果，没有正文归档。

参考实现：[weread-mp-fetcher 的 `__biz` 解析](https://github.com/Pengyf04/weread-mp-fetcher/blob/main/lib/mp.mjs)、[分页调度](https://github.com/Pengyf04/weread-mp-fetcher/blob/main/lib/fetchflow.mjs)。
