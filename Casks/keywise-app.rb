cask "keywise-app" do
  version "2.4.0"
  sha256 "e5c390da5927ff619885731353d874f3fcdd71bc9911365824c0b44d4cd14140"

  url "https://github.com/lkraider/keywise/releases/download/v#{version}/Keywise-#{version}-macos.zip"
  name "Keywise"
  desc "Views a local Firefox profile's saved logins"
  homepage "https://github.com/lkraider/keywise"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Keywise.app"

  zap trash: "~/Library/Preferences/br.com.nkey.Keywise.plist"

  caveats do
    <<~EOS
      This app is ad-hoc signed. It is not notarized. On first launch, either:
        - right-click the app in Finder and choose Open, or
        - remove the quarantine attribute yourself:
          xattr -cr "#{appdir}/Keywise.app"
    EOS
  end
end
