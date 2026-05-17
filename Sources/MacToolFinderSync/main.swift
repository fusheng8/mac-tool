import Foundation

@_silgen_name("NSExtensionMain")
private func nsExtensionMain(_ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32

exit(nsExtensionMain(CommandLine.argc, CommandLine.unsafeArgv))
