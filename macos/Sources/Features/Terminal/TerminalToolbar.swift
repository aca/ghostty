import Cocoa

// Custom NSToolbar subclass that displays a centered window title,
// in order to accommodate the titlebar tabs feature.
class TerminalToolbar: NSToolbar, NSToolbarDelegate {
    static private let identifier = NSToolbarItem.Identifier("TitleText")
    private let titleTextField = CenteredDynamicLabel(labelWithString: "👻 Ghostty")
    
    var titleText: String {
        get {
            titleTextField.stringValue
        }
        
        set {
            titleTextField.stringValue = newValue
        }
    }

    var titleFont: NSFont? {
        get {
            titleTextField.font
        }

        set {
            titleTextField.font = newValue
        }
    }

    override init(identifier: NSToolbar.Identifier) {
        super.init(identifier: identifier)
        
        delegate = self
        
        if #available(macOS 13.0, *) {
            centeredItemIdentifiers.insert(Self.identifier)
        } else {
            centeredItemIdentifier = Self.identifier
        }
    }
    
    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.identifier else {
            return NSToolbarItem(itemIdentifier: itemIdentifier)
        }
        
        let toolbarItem = NSToolbarItem(itemIdentifier: itemIdentifier)
        toolbarItem.view = self.titleTextField
        toolbarItem.visibilityPriority = .user
        
        // NSToolbarItem.minSize and NSToolbarItem.maxSize are deprecated, and make big ugly
        // warnings in Xcode when you use them, but I cannot for the life of me figure out
        // how to get this to work with constraints. The behavior isn't the same, instead of
        // shrinking the item and clipping the subview, it hides the item as soon as the
        // intrinsic size of the subview gets too big for the toolbar width, regardless of
        // whether I have constraints set on its width, height, or both :/
        //
        // If someone can fix this so we don't have to use deprecated properties: Please do.
        toolbarItem.minSize = NSSize(width: 32, height: 1)
        toolbarItem.maxSize = NSSize(width: 1024, height: self.titleTextField.intrinsicContentSize.height)
        
        toolbarItem.isEnabled = true
        
        return toolbarItem
    }
    
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [Self.identifier, .space]
    }
    
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // These space items are here to ensure that the title remains centered when it starts
        // getting smaller than the max size so starts clipping. Lucky for us, three of the
        // built-in spacers seems to exactly match the space on the left that's reserved for
        // the window buttons.
        return [Self.identifier, .space, .space, .space]
    }
}

/// A label that expands to fit whatever text you put in it and horizontally centers itself in the current window.
fileprivate class CenteredDynamicLabel: NSTextField {
    override func viewDidMoveToSuperview() {
        // Truncate the title when it gets too long, cutting it off with an ellipsis.
        cell?.truncatesLastVisibleLine = true
        cell?.lineBreakMode = .byCharWrapping
        
        // Make the text field as small as possible while fitting its text.
        setContentHuggingPriority(.required, for: .horizontal)
        cell?.alignment = .center
        
        // We've changed some alignment settings, make sure the layout is updated immediately.
        needsLayout = true
    }
}
