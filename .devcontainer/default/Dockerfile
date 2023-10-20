FROM swiftlang/swift:nightly-main-jammy

RUN \
  #
  # Disable apt interactive prompts for this RUN command
  export DEBIAN_FRONTEND="noninteractive" && \
    # 
    # Update apt package list
    apt-get update && \
    # 
    # Install sourcekit-lsp dependencies
    apt-get install -y \
      libsqlite3-dev libncurses5-dev python3 ninja-build && \
    #
    # Install swift-format
    apt-get install -y \
      curl && \
    mkdir /swift-format && \
    curl -L https://github.com/apple/swift-format/archive/refs/heads/release/5.9.tar.gz | tar xz --strip-component=1 -C /swift-format && \
    swift build --package-path /swift-format

ENV \
  PATH="/swift-format/.build/debug:${PATH}"

