import Foundation
import XCTest
@testable import MPArchive

final class ImportedCatalogTests: XCTestCase {
 private let biz = "MzU0MTg4MzQ1MA=="
 private let suffix = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

 func testImportIsIdempotentAndKeepsUnknownTitleUnverified() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {try? FileManager.default.removeItem(at:root)}
  let csv = "wechat_url,found_in_weread_visible,weread_title,cited_by_institution_site,first_citing_site_title\r\n" +
   "https://mp.weixin.qq.com/s?__biz=\(biz)&mid=1&idx=1&sn=\(suffix),yes,已核对标题,no,\r\n" +
   "https://mp.weixin.qq.com/s?__biz=\(biz)&mid=2&idx=1&sn=\(suffix),no,,yes,官网引用页标题\r\n"
  let first = try ImportedCatalogStore.ingest(Data(csv.utf8),biz:biz,accountName:"罕见病信息网",root:root)
  XCTAssertEqual(first.1,2)
  XCTAssertEqual(first.0.articles[0].title,"已核对标题")
  XCTAssertTrue(first.0.articles[1].title.hasPrefix("未核对标题"))
  XCTAssertEqual(first.0.articles[1].published,0)
  let second = try ImportedCatalogStore.ingest(Data(csv.utf8),biz:biz,accountName:"罕见病信息网",root:root)
  XCTAssertEqual(second.1,0)
  XCTAssertEqual(ImportedCatalogStore.load(biz:biz,root:root).articles.count,2)
 }

 func testRejectsForeignAccountWithoutChangingExistingCatalog() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {try? FileManager.default.removeItem(at:root)}
  let valid = "original_url,title\nhttps://mp.weixin.qq.com/s?__biz=\(biz)&mid=1&idx=1&sn=\(suffix),一篇\n"
  _ = try ImportedCatalogStore.ingest(Data(valid.utf8),biz:biz,accountName:"罕见病信息网",root:root)
  let mixed = valid + "https://mp.weixin.qq.com/s?__biz=other&mid=2&idx=1&sn=\(suffix),其他号\n"
  XCTAssertThrowsError(try ImportedCatalogStore.ingest(Data(mixed.utf8),biz:biz,accountName:"罕见病信息网",root:root))
  XCTAssertEqual(ImportedCatalogStore.load(biz:biz,root:root).articles.count,1)
 }

 func testQuotedCommaAndNewlineInTitle() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {try? FileManager.default.removeItem(at:root)}
  let csv = "original_url,title\r\n\"https://mp.weixin.qq.com/s?__biz=\(biz)&mid=1&idx=1&sn=\(suffix)\",\"含逗号,和换行\r\n标题\"\r\n"
  let result = try ImportedCatalogStore.ingest(Data(csv.utf8),biz:biz,accountName:"罕见病信息网",root:root)
  XCTAssertEqual(result.0.articles.first?.title,"含逗号,和换行\n标题")
 }
}
