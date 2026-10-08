import CryptoKit
import Foundation

struct OfflineBody: Codable, Identifiable, Sendable {
 let id: String
 let title: String
 let originalURL: String
 let institutionURL: String
 let source: String
 let text: String

 var sourceLabel: String {
  source == "weread_reader" ? "微信读书阅读页正文" : "机构官网同名页参考正文"
 }
}

struct OfflineBodyCatalog: Codable, Sendable {
 let biz: String
 let accountName: String
 let bodies: [OfflineBody]
 let updated: Int64
 static let empty = OfflineBodyCatalog(biz:"",accountName:"",bodies:[],updated:0)
 var readerCount: Int {bodies.filter{$0.source == "weread_reader"}.count}
 var institutionCount: Int {bodies.filter{$0.source == "institution_site_same_title"}.count}
}

enum OfflineBodyStore {
 static let maxBytes = 20_000_000
 static let maxRows = 20_000

 private struct SourceRow: Decodable {
  let group_index: Int?
  let sub_index: Int?
  let title: String
  let status: String
  let body_source: String?
  let body_text: String?
  let original_url: String?
  let institution_site_url: String?
 }

 static func file(for biz:String,root:URL? = nil) -> URL {
  let hash = SHA256.hash(data:Data(biz.utf8)).map{String(format:"%02x",$0)}.joined()
  return ImportedCatalogStore.directory(root:root).appendingPathComponent(hash+".bodies.json")
 }

 static func load(biz:String,root:URL? = nil) -> OfflineBodyCatalog {
  guard let data = try? Data(contentsOf:file(for:biz,root:root)),
        let catalog = try? JSONDecoder().decode(OfflineBodyCatalog.self,from:data),
        catalog.biz == biz else {return .empty}
  return catalog
 }

 static func ingest(_ data:Data,biz:String,accountName:String,root:URL? = nil) throws -> OfflineBodyCatalog {
  guard !biz.isEmpty,!accountName.isEmpty else {throw APIError(code:0,message:"请先选择目标公众号")}
  guard data.count <= maxBytes else {throw APIError(code:0,message:"正文档案超过 20 MB，请拆分后导入")}
  guard let text = String(data:data,encoding:.utf8) else {throw APIError(code:0,message:"正文档案必须是 UTF-8 JSONL")}
  let lines = text.split(separator:"\n",omittingEmptySubsequences:true)
  guard lines.count <= maxRows else {throw APIError(code:0,message:"正文档案超过 20000 行")}
  let decoder = JSONDecoder()
  var bodies:[OfflineBody] = []
  var seen = Set<String>()
  var accountLinks = 0
  for (index,line) in lines.enumerated() {
   let row: SourceRow
   do {row = try decoder.decode(SourceRow.self,from:Data(line.utf8))}
   catch {throw APIError(code:0,message:"第 \(index+1) 行不是有效的正文档案记录")}
   let rawURL = (row.original_url ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
   let canonical: String
   if rawURL.isEmpty {canonical = ""}
   else {
    guard let parsed = canonicalURL(rawURL,biz:biz) else {
     throw APIError(code:0,message:"第 \(index+1) 行微信原文链接不属于当前公众号；未导入任何正文")
    }
    canonical = parsed
    accountLinks += 1
   }
   guard row.status == "reader_text" || row.status == "site_text" else {continue}
   let source = row.body_source ?? ""
   guard source == "weread_reader" || source == "institution_site_same_title" else {
    throw APIError(code:0,message:"第 \(index+1) 行正文来源无法核对")
   }
   guard source != "weread_reader" || !canonical.isEmpty else {
    throw APIError(code:0,message:"第 \(index+1) 行微信读书正文缺少原文链接")
   }
   let title = row.title.trimmingCharacters(in:.whitespacesAndNewlines)
   let bodyText = (row.body_text ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
   guard !title.isEmpty,bodyText.count >= 100 else {continue}
   let identity = canonical.isEmpty ? "\(title)|\(row.group_index ?? -1)|\(row.sub_index ?? -1)|\(source)" : canonical
   let id = String(SHA256.hash(data:Data(identity.utf8)).map{String(format:"%02x",$0)}.joined().prefix(16))
   if seen.insert(id).inserted {
    bodies.append(OfflineBody(id:id,title:title,originalURL:canonical,
                              institutionURL:row.institution_site_url ?? "",source:source,text:bodyText))
   }
  }
  guard accountLinks > 0,!bodies.isEmpty else {throw APIError(code:0,message:"档案没有可核对的当前公众号正文")}
  let catalog = OfflineBodyCatalog(biz:biz,accountName:accountName,bodies:bodies,updated:Int64(Date().timeIntervalSince1970))
  let dir = ImportedCatalogStore.directory(root:root)
  try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  let destination = file(for:biz,root:root)
  try JSONEncoder().encode(catalog).write(to:destination,options:.atomic)
  try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
  return catalog
 }

 static func export(_ catalog:OfflineBodyCatalog,to downloads:URL) throws -> URL {
  guard !catalog.bodies.isEmpty else {throw APIError(code:0,message:"尚未导入可导出的正文")}
  let folder = downloads.appendingPathComponent(Article.safeName(catalog.accountName)+"-已知正文",isDirectory:true)
  let fm = FileManager.default
  for part in ["markdown","text","html","jsonl"] {
   try fm.createDirectory(at:folder.appendingPathComponent(part,isDirectory:true),withIntermediateDirectories:true)
  }
  let encoder = JSONEncoder()
  var jsonLines = Data()
  for body in catalog.bodies {
   let stem = Article.safeName(body.title)+"-"+body.id
   let source = "来源：\(body.sourceLabel)"
   let original = body.originalURL.isEmpty ? "" : "\n微信原文链接：\(body.originalURL)"
   let institution = body.institutionURL.isEmpty ? "" : "\n机构官网链接：\(body.institutionURL)"
   let header = "\(body.title)\n\(source)\(original)\(institution)\n\n"
   let markdown = "# \(body.title)\n\n\(source)\(original)\(institution)\n\n---\n\n\(body.text)\n"
   try Data(markdown.utf8).write(to:folder.appendingPathComponent("markdown/"+stem+".md"),options:.atomic)
   try Data((header+body.text+"\n").utf8).write(to:folder.appendingPathComponent("text/"+stem+".txt"),options:.atomic)
   let html = "<!doctype html><html lang=\"zh\"><meta charset=\"utf-8\"><title>\(escape(body.title))</title><body><h1>\(escape(body.title))</h1><p>\(escape(source))</p><p>\(escape(original+institution).replacingOccurrences(of:"\n",with:"<br>"))</p><pre style=\"white-space:pre-wrap\">\(escape(body.text))</pre></body></html>"
   try Data(html.utf8).write(to:folder.appendingPathComponent("html/"+stem+".html"),options:.atomic)
   jsonLines.append(try encoder.encode(body))
   jsonLines.append(0x0a)
  }
  try jsonLines.write(to:folder.appendingPathComponent("jsonl/已知正文与来源.jsonl"),options:.atomic)
  return folder
 }

 private static func canonicalURL(_ raw:String,biz:String) -> String? {
  guard var parts = URLComponents(string:raw),parts.scheme?.lowercased() == "https",
        parts.host?.lowercased() == "mp.weixin.qq.com",parts.path == "/s" else {return nil}
  let params = Dictionary((parts.queryItems ?? []).map{($0.name,$0.value ?? "")},uniquingKeysWith:{first,_ in first})
  guard params["__biz"] == biz,
        let mid = params["mid"],!mid.isEmpty,mid.allSatisfy({$0.isNumber}),
        let idx = params["idx"],!idx.isEmpty,idx.allSatisfy({$0.isNumber}),
        let sn = params["sn"],sn.count == 32,sn.allSatisfy({$0.isHexDigit}) else {return nil}
  parts.fragment = nil
  parts.queryItems = ["__biz","idx","mid","sn"].map{URLQueryItem(name:$0,value:params[$0])}
  return parts.url?.absoluteString
 }

 private static func escape(_ text:String) -> String {
  text.replacingOccurrences(of:"&",with:"&amp;")
   .replacingOccurrences(of:"<",with:"&lt;")
   .replacingOccurrences(of:">",with:"&gt;")
   .replacingOccurrences(of:"\"",with:"&quot;")
 }
}
