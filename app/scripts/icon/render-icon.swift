#!/usr/bin/env swift
// 앱 아이콘 원본(1024px PNG)을 코드로 그립니다.
// 외부 디자인 도구 없이 레포만으로 아이콘을 재생성할 수 있게 하려는 의도입니다.
// 메뉴바에서 쓰는 SF Symbol `sparkles`를 macOS 스타일 둥근 사각형 위에 얹습니다.
//
// 사용법: swift render-icon.swift <출력 PNG 경로>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS 아이콘 가이드라인은 1024 캔버스에서 약 824px 크기의 둥근 사각형을 권합니다.
// 나머지는 투명 여백으로 두어 다른 앱 아이콘과 크기감이 맞습니다.
let inset = (size - 824) / 2
let rect = NSRect(x: inset, y: inset, width: 824, height: 824)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

// 배경: 위에서 아래로 살짝 어두워지는 파란 계열 그라데이션입니다.
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.32, green: 0.62, blue: 1.00, alpha: 1),
    NSColor(calibratedRed: 0.12, green: 0.36, blue: 0.85, alpha: 1),
])!
gradient.draw(in: path, angle: -90)

// 심볼: 흰색 sparkles. 배경의 약 60% 크기로 가운데에 놓습니다.
let config = NSImage.SymbolConfiguration(pointSize: 520, weight: .medium)
if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let tinted = NSImage(size: symbol.size, flipped: false) { drawRect in
        symbol.draw(in: drawRect)
        NSColor.white.set()
        drawRect.fill(using: .sourceAtop)
        return true
    }
    let s = tinted.size
    let origin = NSPoint(x: (size - s.width) / 2, y: (size - s.height) / 2)
    // 살짝 그림자를 넣어 배경과 분리되게 합니다.
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 24
    shadow.set()
    tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("PNG 변환에 실패했습니다\n", stderr); exit(1)
}
try! png.write(to: URL(fileURLWithPath: output))
print("생성: \(output)")
