import SwiftUI

/// Use `@ViewState` wherever you would write `@State`.
///
/// In the macOS 27 SDK `@State` resolves to a macro, and its compiler plugin
/// (SwiftUIMacros) ships only with Xcode, so it fails to build with just the
/// Command Line Tools. The alias names the `State` property wrapper directly,
/// which skips the macro and behaves the way `@State` always has.
typealias ViewState = SwiftUI.State
