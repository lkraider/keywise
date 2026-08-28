class Keywise < Formula
  desc "Terminal UI to view a local Firefox profile's saved logins"
  homepage "https://github.com/lkraider/keywise"
  url "https://github.com/lkraider/keywise/releases/download/v2.3.0/keywise-aarch64-macos.tar.gz"
  # scripts/release-package.sh writes this tarball byte for byte on any
  # macOS host, so a local run reproduces this hash. docs/REPRODUCIBLE.md
  # names the settings. ci.yml's reproducible-build job prints it on every
  # push, and release.yml compares it with the asset it uploads.
  sha256 "8099c44103cc47863bc2de590046236664e8afcc85bf79e347b3d0e15a1ab2b5"
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
