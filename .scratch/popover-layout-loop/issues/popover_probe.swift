import AppKit
import SwiftUI

final class ProbeDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    func mark(_ s: String) {
        try? s.write(toFile: "/tmp/popover_probe_state.txt", atomically: true, encoding: .utf8)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem.button?.title = "◍"
        popover.contentSize = NSSize(width: 360, height: 460)
        popover.contentViewController = NSHostingController(rootView: ProbeContent())
        mark("launched")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            self.popover.show(
                relativeTo: self.statusItem.button!.bounds,
                of: self.statusItem.button!,
                preferredEdge: .minY
            )
            self.mark("OPENED")
            for i in 1 ... 11 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i * 5)) {
                    self.mark("open+\(i * 5)s")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { NSApplication.shared.terminate(nil) }
        }
    }
}

struct ProbeContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0 ..< 14, id: \.self) { i in
                HStack { Text("探针行 \(i)").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("\(i * 7)%").font(.system(size: 12)).monospacedDigit()
                }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }
}

let app = NSApplication.shared
let delegate = ProbeDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
