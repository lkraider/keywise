class Keywise < Formula
  desc "Terminal UI to view a local Firefox profile's saved logins"
  homepage "https://github.com/lkraider/keywise"
  url "https://github.com/lkraider/keywise/releases/download/v2.2.0/keywise-aarch64-macos.tar.gz"
  # scripts/release-package.sh writes this tarball byte for byte on any
  # macOS host, so a local run reproduces this hash. docs/REPRODUCIBLE.md
  # names the settings. ci.yml's reproducible-build job prints it on every
  # push, and release.yml compares it with the asset it uploads.
  sha256 "1af513788208cd0128aae8e4afc08f8b76fb93f25f98077f6d0939bd057a240f"
  license "MIT"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  def install
    bin.install "keywise"
  end

  test do
    assert_path_exists bin/"keywise"
    assert_predicate bin/"keywise", :executable?
  end
end
