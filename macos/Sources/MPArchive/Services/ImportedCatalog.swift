import CryptoKit
import Foundation

struct ImportedCatalog: Codable {
 let biz: String
 let accountName: String
 var articles: [Article]
 var updated: Int64
 static let empty = ImportedCatalog(biz:"",accountName:"",articles:[],updated:0)
}

enum ImportedCatalogStore {
 static let maxBytes = 10_000_000
 static let maxRows = 20_000

 static func directory(root:URL? = nil) -> URL {
  root ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
   .appendingPathComponent("MPArticleDownloader/imports",isDirectory:true)
 }
 static func file(for biz:String,root:URL? = nil) -> URL {
  let hash = SHA256.hash(data:Data(biz.utf8)).map{String(format:"%02x",$0)}.joined()
  return directory(root:root).appendingPathComponent(hash+".json")
 }
 static func load(biz:String,root:URL? = nil) -> ImportedCatalog {
  guard let data = try? Data(contentsOf:file(for:biz,root:root)),
        let catalog = try? JSONDecoder().decode(ImportedCatalog.self,from:data),
        catalog.biz == biz else {return .empty}
  return catalog
 }
 static func ingest(_ data:Data,biz:String,accountName:String,root:URL? = nil) throws -> (ImportedCatalog,Int) {
  guard !biz.isEmpty,!accountName.isEmpty else {throw APIError(code:0,message:"请先选择目标公众号")}
  guard data.count <= maxBytes else {throw APIError(code:0,message:"清单超过 10 MB，请拆分后导入")}
  guard var text = String(data:data,encoding:.utf8) else {throw APIError(code:0,message:"清单必须是 UTF-8 CSV 文件")}
  if text.hasPrefix("\u{FEFF}") {text.removeFirst()}
  let rows = try parseCSV(text.replacingOccurrences(of:"\r\n",with:"\n"))
  guard let header = rows.first else {throw APIError(code:0,message:"CSV 文件为空")}
  let columns = Dictionary(header.enumerated().map{($0.element.trimmingCharacters(in:.whitespacesAndNewlines).lowercased(),$0.offset)},uniquingKeysWith:{first,_ in first})
  guard ["wechat_url","original_url","url"].contains(where:{columns[$0] != nil}) else {
   throw APIError(code:0,message:"CSV 需要 wechat_url、original_url 或 url 列")
  }
  guard rows.count - 1 <= maxRows else {throw APIError(code:0,message:"清单超过 20000 行，请拆分后导入")}
  var imported:[Article] = []
  var seen = Set<String>()
  for (offset,row) in rows.dropFirst().enumerated() {
   if row.allSatisfy({$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}) {continue}
   let raw = value(row,columns,["wechat_url","original_url","url"])
   guard let article = makeArticle(raw:raw,row:row,columns:columns,biz:biz) else {
    throw APIError(code:0,message:"第 \(offset+2) 行不是当前公众号的完整微信文章长链接；未导入任何内容")
   }
   if seen.insert(article.id).inserted {imported.append(article)}
  }
  guard !imported.isEmpty else {throw APIError(code:0,message:"清单没有可导入的文章链接")}
  var catalog = load(biz:biz,root:root)
  if catalog.biz.isEmpty {catalog = ImportedCatalog(biz:biz,accountName:accountName,articles:[],updated:0)}
  var existing = Set(catalog.articles.map(\.id))
  var added = 0
  for article in imported where existing.insert(article.id).inserted {
   catalog.articles.append(article)
   added += 1
  }
  catalog.updated = Int64(Date().timeIntervalSince1970)
  let dir = directory(root:root)
  try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  let destination = file(for:biz,root:root)
  try JSONEncoder().encode(catalog).write(to:destination,options:.atomic)
  try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
  return (catalog,added)
 }

 private static func value(_ row:[String],_ columns:[String:Int],_ names:[String]) -> String {
  for name in names {
   if let index = columns[name],index < row.count {
    let item = row[index].trimmingCharacters(in:.whitespacesAndNewlines)
    if !item.isEmpty {return item}
   }
  }
  return ""
 }
 private static func makeArticle(raw:String,row:[String],columns:[String:Int],biz:String) -> Article? {
  guard var parts = URLComponents(string:raw),parts.scheme?.lowercased() == "https",
        parts.host?.lowercased() == "mp.weixin.qq.com",parts.path == "/s" else {return nil}
  let parameters = Dictionary((parts.queryItems ?? []).map{($0.name,$0.value ?? "")},uniquingKeysWith:{first,_ in first})
  guard parameters["__biz"] == biz,
        let mid = parameters["mid"],!mid.isEmpty,mid.allSatisfy({$0.isNumber}),
        let idx = parameters["idx"],!idx.isEmpty,idx.allSatisfy({$0.isNumber}),
        let sn = parameters["sn"],sn.count == 32,sn.allSatisfy({$0.isHexDigit}) else {return nil}
  parts.fragment = nil
  parts.queryItems = ["__biz","idx","mid","sn"].map{URLQueryItem(name:$0,value:parameters[$0])}
  guard let canonical = parts.url?.absoluteString else {return nil}
  let id = String(SHA256.hash(data:Data(canonical.utf8)).map{String(format:"%02x",$0)}.joined().prefix(16))
  let title = value(row,columns,["weread_title","title"])
  let displayed = value(row,columns,["weread_displayed_time"])
  let knownReader = value(row,columns,["found_in_weread_visible"]) == "yes" || !value(row,columns,["status"]).isEmpty
  let source = knownReader ? "微信读书目录 · 已知标题" : value(row,columns,["cited_by_institution_site"]) == "yes" ? "官网引用 · 标题待核对" : "导入链接 · 标题待核对"
  let published = parseAbsoluteDate(displayed)
  return Article(id:id,title:title.isEmpty ? "未核对标题 · \(mid)/\(idx)" : title,url:canonical,digest:source,published:published)
 }
 private static func parseAbsoluteDate(_ text:String) -> Int64 {
  guard text.range(of:#"^\d{4}/\d{1,2}/\d{1,2}"#,options:.regularExpression) != nil else {return 0}
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier:"en_US_POSIX")
  formatter.timeZone = TimeZone(identifier:"Asia/Shanghai")
  formatter.dateFormat = text.contains(":") ? "yyyy/M/d HH:mm" : "yyyy/M/d"
  return formatter.date(from:text).map{Int64($0.timeIntervalSince1970)} ?? 0
 }
 private static func parseCSV(_ text:String) throws -> [[String]] {
  let chars = Array(text)
  var rows:[[String]] = [],row:[String] = [],field = "",quoted = false,index = 0
  while index < chars.count {
   let char = chars[index]
   if quoted {
    if char == "\"" {
     if index+1 < chars.count,chars[index+1] == "\"" {field.append("\"");index += 1}
     else {quoted = false}
    } else {field.append(char)}
   } else {
    switch char {
    case "\"" where field.isEmpty: quoted = true
    case ",": row.append(field);field = ""
    case "\n": row.append(field);rows.append(row);row = [];field = ""
    case "\r": break
    default: field.append(char)
    }
   }
   index += 1
  }
  if quoted {throw APIError(code:0,message:"CSV 引号未闭合")}
  if !row.isEmpty || !field.isEmpty {row.append(field);rows.append(row)}
  return rows
 }
}
