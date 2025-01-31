import Cocoa

class TerminalWindow: NSWindow {
    // Both of these must be true for windows without decorations to be able to
    // still become key/main and receive events.
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return true }
    
    // MARK: - NSWindow
    
    override var title: String {
        didSet {
            tab.attributedTitle = attributedTitle
        }
    }

    override func becomeKey() {
        // This is required because the removeTitlebarAccessoryViewControlle hook does not
        // catch the creation of a new window by "tearing off" a tab from a tabbed window.
        if let tabGroup = self.tabGroup, tabGroup.windows.count < 2 {
            hideCustomTabBarViews()
        }
        
        super.becomeKey()

        if titlebarTabs {
            updateNewTabButtonOpacity()
        }

        tab.attributedTitle = attributedTitle
    }

    override func resignKey() {
        super.resignKey()

        if titlebarTabs {
            updateNewTabButtonOpacity()
        }

        tab.attributedTitle = attributedTitle
    }

    // MARK: - Titlebar Tabs
    
    // Used by the window controller to enable/disable titlebar tabs.
    var titlebarTabs = false {
        didSet {
            changedTitlebarTabs(to: titlebarTabs)
        }
    }
    
    // Used to set the titlebar font.
    var titlebarFont: NSFont? {
        didSet {
            titlebarTextField?.font = titlebarFont
            tab.attributedTitle = attributedTitle

            if let toolbar = toolbar as? TerminalToolbar {
                toolbar.titleFont = titlebarFont
            }
        }
    }

    // Find the NSTextField responsible for displaying the titlebar's title.
    private var titlebarTextField: NSTextField? {
        guard let titlebarContainer = contentView?.superview?.subviews
            .first(where: { $0.className == "NSTitlebarContainerView" }) else { return nil }
        guard let titlebarView = titlebarContainer.subviews
            .first(where: { $0.className == "NSTitlebarView" }) else { return nil }
        return titlebarView.subviews.first(where: { $0 is NSTextField }) as? NSTextField
    }

    // Return a styled representation of our title property.
    private var attributedTitle: NSAttributedString? {
        guard let titlebarFont else { return nil }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: titlebarFont,
            .foregroundColor: isKeyWindow ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ]
        return NSAttributedString(string: title, attributes: attributes)
    }

    private var windowButtonsBackdrop: WindowButtonsBackdropView? = nil
    private var windowDragHandle: WindowDragView? = nil
    private var storedTitlebarBackgroundColor: CGColor? = nil
    private var newTabButtonImageLayer: VibrantLayer? = nil

    // The tab bar controller ID from macOS
    static private let TabBarController = NSUserInterfaceItemIdentifier("_tabBarController")

    // Look through the titlebar's view hierarchy and hide any of the internal
    // views used to create a separator between the title/toolbar and unselected
    // tabs in the tab bar.
    override func updateConstraintsIfNeeded() {
        super.updateConstraintsIfNeeded()

        // For titlebar tabs, we want to hide the separator view so that we get rid
        // of an aesthetically unpleasing shadow.
        guard titlebarTabs else { return }

        guard let titlebarContainer = contentView?.superview?.subviews.first(where: {
            $0.className == "NSTitlebarContainerView"
        }) else { return }

        for v in titlebarContainer.descendants(withClassName: "NSTitlebarSeparatorView") {
            v.isHidden = true
        }
    }

    /// This is called by titlebarTabs changing so that we can setup the rest of our window
    private func changedTitlebarTabs(to newValue: Bool) {
        if (newValue) {
            // By hiding the visual effect view, we allow the window's (or titlebar's in this case)
            // background color to show through. If we were to set `titlebarAppearsTransparent` to true
            // the selected tab would look fine, but the unselected ones and new tab button backgrounds
            // would be an opaque color. When the titlebar isn't transparent, however, the system applies
            // a compositing effect to the unselected tab backgrounds, which makes them blend with the
            // titlebar's/window's background.
            if let titlebarContainer = contentView?.superview?.subviews.first(where: {
                $0.className == "NSTitlebarContainerView"
            }), let effectView = titlebarContainer.descendants(withClassName: "NSVisualEffectView").first {
                effectView.isHidden = true
            }

            self.titlebarSeparatorStyle = .none

            // We use the toolbar to anchor our tab bar positions in the titlebar,
            // so we make sure it's the right size/position, and exists.
            self.toolbarStyle = .unifiedCompact
            if (self.toolbar == nil) {
                self.toolbar = TerminalToolbar(identifier: "Toolbar")
            }
            
            // Set a custom background on the titlebar - this is required for when
            // titlebar tabs is used in conjunction with a transparent background.
            self.restoreTitlebarBackground()

            // Reset the new tab button image so that we are sure to generate a fresh
            // one, tinted appropriately for the given theme.
            self.newTabButtonImageLayer = nil

            // We have to wait before setting the titleVisibility or else it prevents
            // the window from hiding the tab bar when we get down to a single tab.
            DispatchQueue.main.async {
                self.titleVisibility = .hidden
            }
        } else {
            // "expanded" places the toolbar below the titlebar, so setting this style and
            // removing the toolbar ensures that the titlebar will be the default height.
            self.toolbarStyle = .expanded
            self.toolbar = nil
            
            // Reset the appearance to whatever our app global value is
            self.appearance = nil
        }
    }
    
    // Assign a background color to the titlebar area.
    func setTitlebarBackground(_ color: CGColor) {
        storedTitlebarBackgroundColor = color
        
        guard let titlebarContainer = contentView?.superview?.subviews.first(where: {
            $0.className == "NSTitlebarContainerView"
        }) else { return }

        titlebarContainer.wantsLayer = true
        titlebarContainer.layer?.backgroundColor = color
    }
    
    // Make sure the titlebar has the assigned background color.
    private func restoreTitlebarBackground() {
        guard let color = storedTitlebarBackgroundColor else { return }
        setTitlebarBackground(color)
    }
    
    // This is called by macOS for native tabbing in order to add the tab bar. We hook into
    // this, detect the tab bar being added, and override its behavior.
    override func addTitlebarAccessoryViewController(_ childViewController: NSTitlebarAccessoryViewController) {
        let isTabBar = self.titlebarTabs && (
            childViewController.layoutAttribute == .bottom ||
            childViewController.identifier == Self.TabBarController
        )
        
        if (isTabBar) {
            // Ensure it has the right layoutAttribute to force it next to our titlebar
            childViewController.layoutAttribute = .right
            
            // If we don't set titleVisibility to hidden here, the toolbar will display a
            // "collapsed items" indicator which interferes with the tab bar.
            titleVisibility = .hidden
            
            // Mark the controller for future reference so we can easily find it. Otherwise
            // the tab bar has no ID by default.
            childViewController.identifier = Self.TabBarController
        }
        
        super.addTitlebarAccessoryViewController(childViewController)
        
        if (isTabBar) {
            pushTabsToTitlebar(childViewController)
        }
    }
    
    override func removeTitlebarAccessoryViewController(at index: Int) {
        let isTabBar = titlebarAccessoryViewControllers[index].identifier == Self.TabBarController
        super.removeTitlebarAccessoryViewController(at: index)
        if (isTabBar) {
            hideCustomTabBarViews()
        }
    }
    
    // To be called immediately after the tab bar is disabled.
    private func hideCustomTabBarViews() {
        // Hide the window buttons backdrop.
        windowButtonsBackdrop?.isHidden = true
        
        // Hide the window drag handle.
        windowDragHandle?.isHidden = true
    }
    
    private func pushTabsToTitlebar(_ tabBarController: NSTitlebarAccessoryViewController) {
        let accessoryView = tabBarController.view
        guard let accessoryClipView = accessoryView.superview else { return }
        guard let titlebarView = accessoryClipView.superview else { return }
        guard titlebarView.className == "NSTitlebarView" else { return }
        guard let toolbarView = titlebarView.subviews.first(where: {
            $0.className == "NSToolbarView"
        }) else { return }

        addWindowButtonsBackdrop(titlebarView: titlebarView, toolbarView: toolbarView)
        guard let windowButtonsBackdrop = windowButtonsBackdrop else { return }
        
        addWindowDragHandle(titlebarView: titlebarView, toolbarView: toolbarView)
        
        accessoryClipView.translatesAutoresizingMaskIntoConstraints = false
        accessoryClipView.leftAnchor.constraint(equalTo: windowButtonsBackdrop.rightAnchor).isActive = true
        accessoryClipView.rightAnchor.constraint(equalTo: toolbarView.rightAnchor).isActive = true
        accessoryClipView.topAnchor.constraint(equalTo: toolbarView.topAnchor).isActive = true
        accessoryClipView.heightAnchor.constraint(equalTo: toolbarView.heightAnchor).isActive = true
        accessoryClipView.needsLayout = true
        
        accessoryView.translatesAutoresizingMaskIntoConstraints = false
        accessoryView.leftAnchor.constraint(equalTo: accessoryClipView.leftAnchor).isActive = true
        accessoryView.rightAnchor.constraint(equalTo: accessoryClipView.rightAnchor).isActive = true
        accessoryView.topAnchor.constraint(equalTo: accessoryClipView.topAnchor).isActive = true
        accessoryView.heightAnchor.constraint(equalTo: accessoryClipView.heightAnchor).isActive = true
        accessoryView.needsLayout = true
        
        // This is a horrible hack. During the transition while things are resizing to make room for
        // new tabs or expand existing tabs to fill the empty space after one is closed, the centering
        // of the tab titles can't be properly calculated, so we wait for 0.2 seconds and then mark
        // the entire view hierarchy for the tab bar as dirty to fix the positioning...
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.markHierarchyForLayout(accessoryView)
        }
    }

    override func update() {
        super.update()

        guard titlebarTabs else { return }

        // This is called when we open, close, switch, and reorder tabs, at which point we determine if the
        // first tab in the tab bar is selected. If it is, we make the `windowButtonsBackdrop` color the same
        // as that of the active tab (i.e. the titlebar's background color), otherwise we make it the same
        // color as the background of unselected tabs.
        if let index = windowController?.window?.tabbedWindows?.firstIndex(of: self) {
            windowButtonsBackdrop?.isHighlighted = index == 0
        }

        // Color the new tab button's image to match the color of the tab title/keyboard shortcut labels,
        // just as it does in the stock tab bar.
        updateNewTabButtonOpacity()

        guard let titlebarContainer = contentView?.superview?.subviews.first(where: {
            $0.className == "NSTitlebarContainerView"
        }) else { return }
        guard let newTabButton: NSButton = titlebarContainer.firstDescendant(withClassName: "NSTabBarNewTabButton") as? NSButton else { return }
        guard let newTabButtonImageView: NSImageView = newTabButton.subviews.first(where: {
            $0 as? NSImageView != nil
        }) as? NSImageView else { return }
        guard let newTabButtonImage = newTabButtonImageView.image else { return }
        guard let storedTitlebarBackgroundColor, let isLightTheme = NSColor(cgColor: storedTitlebarBackgroundColor)?.isLightColor else { return }

        if newTabButtonImageLayer == nil {
            let fillColor: NSColor = isLightTheme ? .black.withAlphaComponent(0.85) : .white.withAlphaComponent(0.85)
            let newImage = NSImage(size: newTabButtonImage.size, flipped: false) { rect in
                newTabButtonImage.draw(in: rect)
                fillColor.setFill()
                rect.fill(using: .sourceAtop)
                return true
            }
            let imageLayer = VibrantLayer(forAppearance: isLightTheme ? .light : .dark)!
            imageLayer.frame = NSRect(origin: NSPoint(x: newTabButton.bounds.midX - newTabButtonImage.size.width/2, y: newTabButton.bounds.midY - newTabButtonImage.size.height/2), size: newTabButtonImage.size)
            imageLayer.contentsGravity = .resizeAspect
            imageLayer.contents = newImage
            imageLayer.opacity = 0.5

            newTabButtonImageLayer = imageLayer
        }

        newTabButtonImageView.layer?.sublayers?.first(where: { $0.className == "VibrantLayer" })?.removeFromSuperlayer()
        newTabButtonImageView.layer?.addSublayer(newTabButtonImageLayer!)
        newTabButtonImageView.image = nil
        // When we nil out the original image, the image view's frame resizes and repositions
        // slightly, so we need to reset it to make sure our new image doesn't shift quickly.
        newTabButtonImageView.frame = newTabButton.bounds
    }

    // Since we are coloring the new tab button's image, it doesn't respond to the
    // window's key status changes in terms of becoming less prominent visually,
    // so we need to do it manually.
    private func updateNewTabButtonOpacity() {
        guard let titlebarContainer = contentView?.superview?.subviews.first(where: {
            $0.className == "NSTitlebarContainerView"
        }) else { return }
        guard let newTabButton: NSButton = titlebarContainer.firstDescendant(withClassName: "NSTabBarNewTabButton") as? NSButton else { return }
        guard let newTabButtonImageView: NSImageView = newTabButton.subviews.first(where: {
            $0 as? NSImageView != nil
        }) as? NSImageView else { return }

        newTabButtonImageView.alphaValue = isKeyWindow ? 1 : 0.5
    }

    private func addWindowButtonsBackdrop(titlebarView: NSView, toolbarView: NSView) {
        // If we already made the view, just make sure it's unhidden and correctly placed as a subview.
        if let view = windowButtonsBackdrop {
            view.removeFromSuperview()
            view.isHidden = false
            titlebarView.addSubview(view)
            view.leftAnchor.constraint(equalTo: toolbarView.leftAnchor).isActive = true
            view.rightAnchor.constraint(equalTo: toolbarView.leftAnchor, constant: 78).isActive = true
            view.topAnchor.constraint(equalTo: toolbarView.topAnchor).isActive = true
            view.heightAnchor.constraint(equalTo: toolbarView.heightAnchor).isActive = true
            return
        }
        
        let view = WindowButtonsBackdropView(backgroundColor: storedTitlebarBackgroundColor ?? NSColor.windowBackgroundColor.cgColor)
        view.identifier = NSUserInterfaceItemIdentifier("_windowButtonsBackdrop")
        titlebarView.addSubview(view)
        
        view.translatesAutoresizingMaskIntoConstraints = false
        view.leftAnchor.constraint(equalTo: toolbarView.leftAnchor).isActive = true
        view.rightAnchor.constraint(equalTo: toolbarView.leftAnchor, constant: 78).isActive = true
        view.topAnchor.constraint(equalTo: toolbarView.topAnchor).isActive = true
        view.heightAnchor.constraint(equalTo: toolbarView.heightAnchor).isActive = true

        windowButtonsBackdrop = view
    }
    
    private func addWindowDragHandle(titlebarView: NSView, toolbarView: NSView) {
        // If we already made the view, just make sure it's unhidden and correctly placed as a subview.
        if let view = windowDragHandle {
            view.removeFromSuperview()
            view.isHidden = false
            titlebarView.superview?.addSubview(view)
            view.leftAnchor.constraint(equalTo: toolbarView.leftAnchor).isActive = true
            view.rightAnchor.constraint(equalTo: toolbarView.rightAnchor).isActive = true
            view.topAnchor.constraint(equalTo: toolbarView.topAnchor).isActive = true
            view.bottomAnchor.constraint(equalTo: toolbarView.topAnchor, constant: 12).isActive = true
            return
        }
        
        let view = WindowDragView()
        view.identifier = NSUserInterfaceItemIdentifier("_windowDragHandle")
        titlebarView.superview?.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.leftAnchor.constraint(equalTo: toolbarView.leftAnchor).isActive = true
        view.rightAnchor.constraint(equalTo: toolbarView.rightAnchor).isActive = true
        view.topAnchor.constraint(equalTo: toolbarView.topAnchor).isActive = true
        view.bottomAnchor.constraint(equalTo: toolbarView.topAnchor, constant: 12).isActive = true
        
        windowDragHandle = view
    }
    
    // This forces this view and all subviews to update layout and redraw. This is
    // a hack (see the caller).
    private func markHierarchyForLayout(_ view: NSView) {
        view.needsUpdateConstraints = true
        view.needsLayout = true
        view.needsDisplay = true
        view.setNeedsDisplay(view.bounds)
        for subview in view.subviews {
            markHierarchyForLayout(subview)
        }
    }
}

// Passes mouseDown events from this view to window.performDrag so that you can drag the window by it.
fileprivate class WindowDragView: NSView {
    override public func mouseDown(with event: NSEvent) {
        // Drag the window for single left clicks, double clicks should bypass the drag handle.
        if (event.type == .leftMouseDown && event.clickCount == 1) {
            window?.performDrag(with: event)
            NSCursor.closedHand.set()
        } else {
            super.mouseDown(with: event)
        }
    }
    
    override public func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        window?.disableCursorRects()
        NSCursor.openHand.set()
    }
    
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        window?.enableCursorRects()
        NSCursor.arrow.set()
    }
    
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

// A view that matches the color of selected and unselected tabs in the adjacent tab bar.
fileprivate class WindowButtonsBackdropView: NSView {
    private let overlayLayer = VibrantLayer()
    private let isLightTheme: Bool

    var isHighlighted: Bool = true {
        didSet {
            if isLightTheme {
                overlayLayer.isHidden = isHighlighted
                layer?.backgroundColor = .clear
            } else {
                overlayLayer.isHidden = true
                layer?.backgroundColor = isHighlighted ? .clear : CGColor(genericGrayGamma2_2Gray: 0.0, alpha: 0.45)
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    init(backgroundColor: CGColor) {
        self.isLightTheme = NSColor(cgColor: backgroundColor)!.isLightColor

        super.init(frame: .zero)

        wantsLayer = true

        overlayLayer.frame = layer!.bounds
        overlayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        overlayLayer.backgroundColor = CGColor(genericGrayGamma2_2Gray: 0.95, alpha: 1)

        layer?.addSublayer(overlayLayer)
    }
}
