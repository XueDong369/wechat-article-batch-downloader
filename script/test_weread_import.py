import base64
import json
from pathlib import Path
import tempfile
import unittest

from weread_import import import_pages, main, resolve_book_id


BOOK = "MP_WXS_3541883450"
ACCOUNT = "罕见病信息网"


def page(*original_ids, account=ACCOUNT, book=BOOK):
    return {
        "reviews": [{
            "createTime": 1791376068,
            "subCount": 1,
            "subReviews": [{"review": {
                "belongBookId": book,
                "userVid": "private-user-marker",
                "content": "A\nB",
                "mpInfo": {"mp_name": account, "title": "文章 " + oid,
                           "originalId": oid, "content": "private-content-marker"},
            }}],
        } for oid in original_ids],
        "synckey": 123,
    }


class WeReadImportTests(unittest.TestCase):
    def test_resolve_book_id_from_biz_and_url(self):
        biz = base64.b64encode(b"3541883450").decode("ascii")
        self.assertEqual(resolve_book_id(biz), BOOK)
        self.assertEqual(resolve_book_id("https://mp.weixin.qq.com/s?__biz=" + biz + "&mid=1"), BOOK)
        with self.assertRaises(ValueError):
            resolve_book_id("https://mp.weixin.qq.com/s/short-token")

    def test_import_repairs_copied_newline_and_deduplicates_overlap(self):
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "first.txt"
            second = Path(directory) / "second.txt"
            first.write_text(json.dumps(page("A~B", "C"), ensure_ascii=False)
                             .replace("A\\nB", "A\nB"), encoding="utf-8")
            second.write_text(json.dumps(page("C", "D"), ensure_ascii=False), encoding="utf-8")
            result = import_pages(ACCOUNT, BOOK, [(0, first), (2, second)])
        self.assertEqual(result["article_count"], 3)
        self.assertEqual(result["pages"][0]["repaired_control_characters"], 2)
        self.assertEqual(result["pages"][1]["duplicate_link_count"], 1)
        self.assertEqual(result["pages"][1]["next_offset_candidate"], 4)
        self.assertTrue(result["articles"][0]["original_url"].endswith("/A_B"))
        output = json.dumps(result)
        self.assertNotIn("private-user-marker", output)
        self.assertNotIn("private-content-marker", output)

    def test_rejects_wrong_account_and_business_error(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "page.json"
            path.write_text(json.dumps(page("A", account="其他号")), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "公众号标识"):
                import_pages(ACCOUNT, BOOK, [(0, path)])
            path.write_text(json.dumps({"errCode": -2041}), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "业务错误"):
                import_pages(ACCOUNT, BOOK, [(0, path)])

    def test_rejects_repeated_page_offset(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "page.json"
            path.write_text(json.dumps(page("A")), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "offset"):
                import_pages(ACCOUNT, BOOK, [(0, path), (0, path)])

    def test_resolve_rejects_non_object_account_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "accounts.json"
            path.write_text("[]", encoding="utf-8")
            self.assertEqual(main(["resolve", "--account-file", str(path), "--name", ACCOUNT]), 1)


if __name__ == "__main__":
    unittest.main()
