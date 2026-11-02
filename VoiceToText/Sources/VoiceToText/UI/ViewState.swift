import SwiftUI

/// SwiftUI's State property wrapper under another name. In the macOS 27
/// SDK, `@State` resolves to a macro whose plugin ships only with Xcode, so
/// a Command Line Tools build fails with "plugin for module 'SwiftUIMacros'
/// not found". The wrapper itself is unchanged: `@ViewState` behaves exactly
/// like `@State`, including `$binding`. With Xcode installed, either works.
typealias ViewState<Value> = SwiftUI.State<Value>
