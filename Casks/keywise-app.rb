cask "keywise-app" do
  version "2.2.0"
  # This is CI's hash. The zip holds the Swift binary, and its LC_UUID
  # follows the macOS SDK installed on the build machine, so a local run
  # writes a different SHA-256. CI builds the asset a release uploads. Read
  # the hash from ci.yml's reproducible-build job. That job prints it on
  # every push.
  sha256 "fe875a8bda9d32153fa4f1895cd6ceba0ce38a637ca5daaf0118e8bb8a7b3958"

  url "https://github.com/lkraider/keywise/releases/download/v#{version}/Keywise-#{version}-macos.zip"
  name "Keywise"
  desc "Views a local Firefox profile's saved logins"
  homepage "https://github.com/lkraider/keywise"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Keywise.app"

  zap trash: "~/Library/Preferences/br.com.nkey.Keywise.plist"

  # The app is ad-hoc signed. This project has no Apple Developer ID, so
  # it is not notarized. Gatekeeper otherwise blocks a first launch as
  # coming from an unidentified developer.
  caveats do
    <<~EOS
      This app is ad-hoc signed. It is not notarized. On first launch, either:
        - right-click the app in Finder and choose Open, or
        - remove the quarantine attribute yourself:
          xattr -cr "#{appdir}/Keywise.app"
    EOS
  end
end
