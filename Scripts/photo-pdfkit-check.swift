import Foundation
import PDFKit
import AppKit
let source = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))!
let candidate = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[2]))!
let out = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
precondition(source.pageCount == candidate.pageCount)
for i in 0..<source.pageCount {
 precondition(source.page(at:i)!.string == candidate.page(at:i)!.string, "PDFKit text mismatch")
 precondition(source.page(at:i)!.bounds(for:.mediaBox) == candidate.page(at:i)!.bounds(for:.mediaBox))
 for (name,doc) in [("source",source),("candidate",candidate)] {
  let page = doc.page(at:i)!
  let bounds = page.bounds(for:.mediaBox)
  let image = page.thumbnail(of:NSSize(width:bounds.width*96/72,height:bounds.height*96/72),for:.mediaBox)
  let rep = NSBitmapImageRep(data:image.tiffRepresentation!)!
  try rep.representation(using:.png,properties:[:])!.write(to:out.appendingPathComponent("\(name)-page\(i+1)-96ppi.png"))
  if i == 3 {
   let image = page.thumbnail(of:NSSize(width:bounds.width*300/72,height:bounds.height*300/72),for:.mediaBox)
   let rep = NSBitmapImageRep(data:image.tiffRepresentation!)!
   try rep.representation(using:.png,properties:[:])!.write(to:out.appendingPathComponent("\(name)-page4-300ppi.png"))
  }
 }
}
print("PDFKit: \(candidate.pageCount) pages; all page text and media boxes identical; 100% and page4 300ppi renders completed")
