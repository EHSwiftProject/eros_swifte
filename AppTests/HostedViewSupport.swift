import SwiftUI
import Testing
import UIKit

@testable import Eros

/// Views on real windows of the host app's scene, and what their accessibility tree holds (the browse B4 view tests).
/// The same way `ListTagViewTests` works: SwiftUI builds the tree only while accessibility is on, which this turns on.
///
/// A window here can have a horizontal safe area: on the iPhone Duo's outer screen, held upright, the scene keeps a
/// rail 84 pt wide on the right for the bars it stands upright (design §5.4), and the window's safe area takes it in
/// whatever the window's size (M2 review F6: a window 881 wide kept 797 for its content). A page lays its content out
/// beside the rail, centered in what is left, so horizontal positions are asserted against the content region
/// (`contentRegion(of:)`), not against the window's width. An accessibility frame is in the screen's coordinates:
/// `frame(of:in:)` brings it into the window's before it is compared with a view's frame.
@MainActor enum HostedViews {
    /// `view` with `environment` as the root of a window of its own (`size`); returns the root controller.
    static func show(
        _ view: some View, environment: AppEnvironment, size: CGSize = CGSize(width: 390, height: 700)
    ) throws -> UIHostingController<AnyView> {
        #expect(accessibilityIsOn, "libAccessibility did not offer a way to turn accessibility on")
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let controller = UIHostingController(rootView: AnyView(view.environment(environment)))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        windows[ObjectIdentifier(controller)] = window
        return controller
    }

    /// What the window of `controller` (from `show`) lays its content out in, in the window's coordinates: its root
    /// view's bounds inside the safe area. Horizontally that is the window less the Duo's rail, if there is one.
    static func contentRegion(of controller: UIViewController) -> CGRect {
        let root = controller.view!
        return root.convert(root.bounds.inset(by: root.safeAreaInsets), to: nil)
    }

    /// The accessibility frame of `element` in the coordinates of `window`: the frame is given in the screen's, which
    /// are the window's only while the window stands at the screen's origin.
    static func frame(of element: NSObject, in window: UIWindow) -> CGRect {
        window.convert(element.accessibilityFrame, from: window.screen.coordinateSpace)
    }

    /// Takes the window of `controller` down.
    static func hide(_ controller: UIViewController) {
        guard let window = windows.removeValue(forKey: ObjectIdentifier(controller)) else { return }
        window.isHidden = true
        window.rootViewController = nil
    }

    /// The accessibility identifiers under `root`.
    static func identifiers(in root: NSObject) -> [String] {
        elements(in: root).compactMap(identifier(of:))
    }

    /// The accessibility label of the element identified `identifier` under `root`, if there is one.
    static func label(of identifier: String, in root: NSObject) -> String? {
        elements(in: root).first { Self.identifier(of: $0) == identifier }?.accessibilityLabel
    }

    /// Every accessibility element under `root`, through accessibility elements and subviews, each once: the same
    /// node is often reachable both ways, and walking every path grows exponentially with the depth of a list's tree.
    static func elements(in root: NSObject) -> [NSObject] {
        var found: [NSObject] = []
        var visited: Set<ObjectIdentifier> = []
        var pending: [NSObject] = [root]
        while let node = pending.popLast() {
            guard visited.insert(ObjectIdentifier(node)).inserted else { continue }
            found.append(node)
            var children: [NSObject] = []
            if let elements = node.accessibilityElements as? [NSObject] {
                children = elements
            } else {
                // Some nodes answer NSNotFound (no indexed children): only a plausible count is walked.
                let count = node.accessibilityElementCount()
                for index in 0..<(0..<10_000 ~= count ? count : 0) {
                    if let child = node.accessibilityElement(at: index) as? NSObject { children.append(child) }
                }
            }
            if let view = node as? UIView { children += view.subviews }
            pending += children.reversed()
        }
        return found
    }

    /// The accessibility identifier of `element`, if it has one. SwiftUI's accessibility nodes are plain NSObjects
    /// that answer the identification selector without conforming to `UIAccessibilityIdentification`.
    static func identifier(of element: NSObject) -> String? {
        element.responds(to: Selector(("accessibilityIdentifier")))
            ? element.value(forKey: "accessibilityIdentifier") as? String : nil
    }

    /// libAccessibility's `_AXSApplicationAccessibilitySetEnabled`, the way UI automation turns accessibility on.
    private static let accessibilityIsOn: Bool = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXSApplicationAccessibilitySetEnabled")
        else { return false }
        unsafeBitCast(symbol, to: (@convention(c) (Bool) -> Void).self)(true)
        return true
    }()

    private static var windows: [ObjectIdentifier: UIWindow] = [:]
}
