## Fixed

- **Release Test Linker Gate**: Type-erased `SubscriptionSettingsSection.subscriptionForm` via `subscriptionFormAnyView` for `AuditPostFixPolishTests`, preventing Release builds (`swift test -c release`) from emitting an unresolvable `SwiftUICore` opaque type descriptor reference (`View.tag(_:includeOptional:)`).
- **Menu Bar Status Item Spacing**: Set the menu bar status item's left and right horizontal padding to `2pt` via an explicit `MenuBarIcon.statusItemLength(imageWidth:titleWidth:)` calculation on each label/font/badge update, reducing excess default `NSStatusItem.variableLength` side margins without clipping dynamic token text.
