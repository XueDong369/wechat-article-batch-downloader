import Foundation
import XCTest
@testable import MPArchive

final class OfflineBodyCatalogTests: XCTestCase {
 private let biz = "MzU0MTg4MzQ1MA=="
 private let sn = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

 private func row(title:String,mid:Int,source:String,status:String = "reader_text",biz:String = "MzU0MTg4MzQ1MA==") -> String {
  let url = "https://mp.weixin.qq.com/s?__biz=\(biz)&mid=\(mid)&idx=1&sn=\(sn)"
  let fields:[String:Any] = ["group_index":mid,"sub_index":0,"title":title,"status":status,"body_source":source,
                             "body_text":String(repeating:"正文内容。",count:30),"original_url":url,
                             "institution_site_url":source == "institution_site_same_title" ? "https://www.raredisease.cn/News/Info/1" : ""]
  let data = try! JSONSerialization.data(withJSONObject:fields,options:[.sortedKeys])
  return String(data:data,encoding:.utf8)!
 }

 func testExportsProvenanceWithoutCallingSiteTextWeChatOriginal() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {try? FileManager.default.removeItem(at:root)}
  let lines = [row(title:"微信读书文章",mid:1,source:"weread_reader"),
               row(title:"官网同名文章",mid:2,source:"institution_site_same_title",status:"site_text")].joined(separator:"\n")
  let catalog = try OfflineBodyStore.ingest(Data(lines.utf8),biz:biz,accountName:"罕见病信息网",root:root)
  XCTAssertEqual(catalog.readerCount,1)
  XCTAssertEqual(catalog.institutionCount,1)
  let folder = try OfflineBodyStore.export(catalog,to:root.appendingPathComponent("downloads"))
  let site = catalog.bodies.first{$0.source == "institution_site_same_title"}!
  let markdown = try String(contentsOf:folder.appendingPathComponent("markdown/"+Article.safeName(site.title)+"-"+site.id+".md"),encoding:.utf8)
  XCTAssertTrue(markdown.contains("官网同名页参考正文"))
  XCTAssertFalse(markdown.contains("微信读书阅读页正文"))
  XCTAssertTrue(markdown.contains("https://www.raredisease.cn/News/Info/1"))
  XCTAssertEqual(OfflineBodyStore.load(biz:biz,root:root).bodies.count,2)
 }

 func testMixedAccountRejectsWholeImport() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer {try? FileManager.default.removeItem(at:root)}
  let valid = row(title:"本号文章",mid:1,source:"weread_reader")
  _ = try OfflineBodyStore.ingest(Data(valid.utf8),biz:biz,accountName:"罕见病信息网",root:root)
  let mixed = valid+"\n"+row(title:"其他账号",mid:2,source:"weread_reader",biz:"other")
  XCTAssertThrowsError(try OfflineBodyStore.ingest(Data(mixed.utf8),biz:biz,accountName:"罕见病信息网",root:root))
  XCTAssertEqual(OfflineBodyStore.load(biz:biz,root:root).bodies.count,1)
 }
}
