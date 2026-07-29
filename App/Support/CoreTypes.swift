import NuminousCore

// `Axis` collides with SwiftUI.Axis and `Category` with another framework type,
// making bare references ambiguous in the app module. These module-scope
// typealiases shadow the imported names so `Axis`/`Category` unambiguously mean
// our domain types everywhere in the app. (The app never needs SwiftUI.Axis.)
typealias Axis = NuminousCore.Axis
typealias Category = NuminousCore.Category
