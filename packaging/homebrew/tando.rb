# Homebrew formula template. scripts/package.sh homebrew fills the @...@ values from VERSION and
# dist/tando-<version>.tar.gz and writes dist/homebrew/tando.rb; publish that file in a tap repo.
class Tando < Formula
  desc "Deploy apps from your laptop to your own Linux server over ssh"
  homepage "https://github.com/@REPO@"
  url "https://github.com/@REPO@/releases/download/v@VERSION@/tando-@VERSION@.tar.gz"
  sha256 "@SHA256@"
  license @LICENSE@

  # tando runs on macOS /bin/bash 3.2 and uses the system ssh and rsync

  def install
    # the whole release tree (bin, lib, server/linux-{amd64,arm64}, templates, completions):
    # bin/tando follows its symlink to find lib/ next to it
    libexec.install Dir["*"]
    bin.install_symlink libexec/"bin/tando"
    bash_completion.install libexec/"completions/tando.bash" => "tando"
    zsh_completion.install libexec/"completions/_tando"
  end

  test do
    assert_match "tando #{version}", shell_output("#{bin}/tando version")
    assert_path_exists libexec/"server/linux-amd64"
    assert_path_exists libexec/"server/linux-arm64"
  end
end
