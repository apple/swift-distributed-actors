ARG ubuntu_version=18.04
FROM ubuntu:$ubuntu_version
# needed to do again after FROM due to docker limitation
ARG ubuntu_version

ARG DEBIAN_FRONTEND=noninteractive
# do not start services during installation as this will fail and log a warning / error.
RUN echo "#!/bin/sh\nexit 0" > /usr/sbin/policy-rc.d

# basic dependencies
RUN apt-get update && apt-get install -y wget git jq build-essential software-properties-common pkg-config locales
RUN apt-get update && apt-get install -y libicu-dev libblocksruntime0
RUN apt-get update && apt-get install -y lsof dnsutils netcat-openbsd net-tools # used by integration tests

# local
RUN locale-gen en_US.UTF-8
RUN locale-gen en_US en_US.UTF-8
RUN dpkg-reconfigure locales
RUN echo 'export LANG=en_US.UTF-8' >> $HOME/.profile
RUN echo 'export LANGUAGE=en_US:en' >> $HOME/.profile
RUN echo 'export LC_ALL=en_US.UTF-8' >> $HOME/.profile

# known_hosts
RUN mkdir -p $HOME/.ssh
RUN touch $HOME/.ssh/known_hosts
RUN ssh-keyscan github.com 2> /dev/null >> $HOME/.ssh/known_hosts

# clang
RUN apt-get update && apt-get install -y clang-3.9
RUN update-alternatives --install /usr/bin/clang clang /usr/bin/clang-3.9 100
RUN update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-3.9 100

# modern curl, if needed
RUN apt-get update && apt-get install -y curl libcurl4-openssl-dev libz-dev;

# ruby and jazzy for docs generation
RUN apt-get update && apt-get install -y ruby ruby-dev libsqlite3-dev
RUN gem install jazzy --no-ri --no-rdoc
RUN gem install asciidoctor -v 1.5.8 --no-ri --no-rdoc
RUN gem install asciidoctor-pdf --pre --no-ri --no-rdoc
RUN gem install asciidoctor-diagram -v 1.5.8 --no-ri --no-rdoc

# swift
ARG swift_version=4.2.1
ARG swift_flavour=RELEASE
ARG swift_builds_suffix=release

RUN mkdir $HOME/.swift
RUN wget -q "https://swift.org/builds/swift-${swift_version}-${swift_builds_suffix}/ubuntu$(echo $ubuntu_version | sed 's/\.//g')/swift-${swift_version}-${swift_flavour}/swift-${swift_version}-${swift_flavour}-ubuntu${ubuntu_version}.tar.gz" -O $HOME/swift.tar.gz
RUN tar xzf $HOME/swift.tar.gz --directory $HOME/.swift --strip-components=1
RUN echo 'export PATH="$HOME/.swift/usr/bin:$PATH"' >> $HOME/.profile
RUN echo 'export LINUX_SOURCEKIT_LIB_PATH="$HOME/.swift/usr/lib"' >> $HOME/.profile

# tools
RUN mkdir -p $HOME/.tools
RUN echo 'export PATH="$HOME/.tools:$PATH"' >> $HOME/.profile

# script to allow mapping framepointers on linux (until part of the toolchain)
RUN wget -q https://raw.githubusercontent.com/apple/swift/master/utils/symbolicate-linux-fatal -O $HOME/.tools/symbolicate-linux-fatal
RUN chmod 755 $HOME/.tools/symbolicate-linux-fatal

# swiftformat (until part of the toolchain)

ARG swiftformat_version=0.40.11
RUN git clone --branch $swiftformat_version --depth 1 https://github.com/nicklockwood/SwiftFormat $HOME/.tools/swift-format
RUN cd $HOME/.tools/swift-format && $HOME/.swift/usr/bin/swift build -c release
RUN ln -s $HOME/.tools/swift-format/.build/release/swiftformat $HOME/.tools/swiftformat
