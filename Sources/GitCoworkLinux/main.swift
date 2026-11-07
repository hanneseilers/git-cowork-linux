import Foundation

// git-cowork for Linux (GTK 4 + libadwaita).
// The same binary answers ssh's passphrase prompts for keys it made (see Askpass).
Askpass.runIfRequested()
MainLoop.install()
exit(MainActor.assumeIsolated { App.shared.run() })
