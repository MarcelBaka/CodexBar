import AppKit

let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.09, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 214, yRadius: 214).fill()
    NSColor(calibratedRed: 0.43, green: 0.94, blue: 0.76, alpha: 1).setFill()
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 512, y: 820))
    path.curve(to: NSPoint(x: 820, y: 512), controlPoint1: NSPoint(x: 556, y: 601), controlPoint2: NSPoint(x: 606, y: 556))
    path.curve(to: NSPoint(x: 512, y: 204), controlPoint1: NSPoint(x: 606, y: 468), controlPoint2: NSPoint(x: 556, y: 423))
    path.curve(to: NSPoint(x: 204, y: 512), controlPoint1: NSPoint(x: 468, y: 423), controlPoint2: NSPoint(x: 418, y: 468))
    path.curve(to: NSPoint(x: 512, y: 820), controlPoint1: NSPoint(x: 418, y: 556), controlPoint2: NSPoint(x: 468, y: 601))
    path.fill()
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let data = bitmap.representation(using: .png, properties: [:])!
    if size <= 512 { try data.write(to: URL(fileURLWithPath: destination + "/icon_\(size)x\(size).png")) }
    if size >= 32 { try data.write(to: URL(fileURLWithPath: destination + "/icon_\(size / 2)x\(size / 2)@2x.png")) }
}
