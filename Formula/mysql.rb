class Mysql < Formula
  desc "Open source relational database management system"
  homepage "https://dev.mysql.com/doc/refman/8.0/en/"
  url "https://cdn.mysql.com/Downloads/MySQL-8.0/mysql-boost-8.0.22.tar.gz"
  sha256 "ba765f74367c638d7cd1c546c05c14382fd997669bcd9680278e907f8d7eb484"
  license "GPL-2.0"
  revision 1

  livecheck do
    url "https://dev.mysql.com/downloads/mysql/"
    regex(/href=.*?mysql[._-]v?(\d+.\d+.\d+)-/i)
  end

  bottle do
    rebuild 1
    sha256 "4032192bba2d0aa3433573019c8b4b6566e9c0aa2f69a493e141cc15f53de63b" => :big_sur
    sha256 "42239a4ab5d73f7ba533cefd0065566e9a68ae8faf977966103b20f80c1fe9d5" => :catalina
    sha256 "ba3267e7fad1b6e2c991a1dc40d2b4177c554a6ae7734fc7c33c3cc26f4d327e" => :mojave
  end

  depends_on "cmake" => :build
  # GCC is not supported either, so exclude for El Capitan.
  depends_on macos: :sierra if DevelopmentTools.clang_build_version == 800
  depends_on "openssl@1.1"
  depends_on "protobuf"

  uses_from_macos "libedit"

  conflicts_with "mariadb", "percona-server",
    because: "mysql, mariadb, and percona install the same binaries"

  # https://bugs.mysql.com/bug.php?id=86711
  # https://github.com/Homebrew/homebrew-core/pull/20538
  fails_with :clang do
    build 800
    cause "Wrong inlining with Clang 8.0, see MySQL Bug #86711"
  end

  def datadir
    var/"mysql"
  end

  def install
    # -DINSTALL_* are relative to `CMAKE_INSTALL_PREFIX` (`prefix`)
    args = %W[
      -DFORCE_INSOURCE_BUILD=1
      -DCOMPILATION_COMMENT=Homebrew
      -DINSTALL_DOCDIR=share/doc/#{name}
      -DINSTALL_INCLUDEDIR=include/mysql
      -DINSTALL_INFODIR=share/info
      -DINSTALL_MANDIR=share/man
      -DINSTALL_MYSQLSHAREDIR=share/mysql
      -DINSTALL_PLUGINDIR=lib/plugin
      -DMYSQL_DATADIR=#{datadir}
      -DSYSCONFDIR=#{etc}
      -DWITH_BOOST=boost
      -DWITH_EDITLINE=system
      -DWITH_SSL=#{Formula["openssl@1.1"].opt_prefix}
      -DWITH_PROTOBUF=system
      -DWITH_UNIT_TESTS=OFF
      -DENABLED_LOCAL_INFILE=1
      -DWITH_INNODB_MEMCACHED=ON
    ]

    system "cmake", ".", *std_cmake_args, *args
    system "make"
    system "make", "install"

    (prefix/"mysql-test").cd do
      system "./mysql-test-run.pl", "status", "--vardir=#{Dir.mktmpdir}"
    end

    # Remove libssl copies as the binaries use the keg anyway and they create problems for other applications
    rm_rf lib/"libssl.dylib"
    rm_rf lib/"libssl.1.1.dylib"
    rm_rf lib/"libcrypto.1.1.dylib"
    rm_rf lib/"libcrypto.dylib"
    rm_rf lib/"plugin/libcrypto.1.1.dylib"
    rm_rf lib/"plugin/libssl.1.1.dylib"

    # Remove the tests directory
    rm_rf prefix/"mysql-test"

    # Don't create databases inside of the prefix!
    # See: https://github.com/Homebrew/homebrew/issues/4975
    rm_rf prefix/"data"

    # Fix up the control script and link into bin.
    inreplace "#{prefix}/support-files/mysql.server",
              /^(PATH=".*)(")/,
              "\\1:#{HOMEBREW_PREFIX}/bin\\2"
    bin.install_symlink prefix/"support-files/mysql.server"

    # Install my.cnf that binds to 127.0.0.1 by default
    (buildpath/"my.cnf").write <<~EOS
      # Default Homebrew MySQL server config
      [mysqld]
      # Only allow connections from localhost
      bind-address = 127.0.0.1
      mysqlx-bind-address = 127.0.0.1
    EOS
    etc.install "my.cnf"
  end

  def post_install
    return if ENV["CI"]

    # Make sure the datadir exists
    datadir.mkpath
    unless (datadir/"mysql/general_log.CSM").exist?
      ENV["TMPDIR"] = nil
      system bin/"mysqld", "--initialize-insecure", "--user=#{ENV["USER"]}",
        "--basedir=#{prefix}", "--datadir=#{datadir}", "--tmpdir=/tmp"
    end
  end

  def caveats
    s = <<~EOS
      We've installed your MySQL database without a root password. To secure it run:
          mysql_secure_installation

      MySQL is configured to only allow connections from localhost by default

      To connect run:
          mysql -uroot
    EOS
    if (my_cnf = ["/etc/my.cnf", "/etc/mysql/my.cnf"].find { |x| File.exist? x })
      s += <<~EOS

        A "#{my_cnf}" from another install may interfere with a Homebrew-built
        server starting up correctly.
      EOS
    end
    s
  end

  plist_options manual: "mysql.server start"

  def plist
    <<~EOS
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>KeepAlive</key>
        <true/>
        <key>Label</key>
        <string>#{plist_name}</string>
        <key>ProgramArguments</key>
        <array>
          <string>#{opt_bin}/mysqld_safe</string>
          <string>--datadir=#{datadir}</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>WorkingDirectory</key>
        <string>#{datadir}</string>
      </dict>
      </plist>
    EOS
  end

  test do
    # Expects datadir to be a completely clean dir, which testpath isn't.
    dir = Dir.mktmpdir
    system bin/"mysqld", "--initialize-insecure", "--user=#{ENV["USER"]}",
    "--basedir=#{prefix}", "--datadir=#{dir}", "--tmpdir=#{dir}"

    port = free_port
    pid = fork do
      exec bin/"mysqld", "--bind-address=127.0.0.1", "--datadir=#{dir}", "--port=#{port}"
    end
    sleep 2

    output = shell_output("curl 127.0.0.1:#{port}")
    output.force_encoding("ASCII-8BIT") if output.respond_to?(:force_encoding)
    assert_match version.to_s, output
  ensure
    Process.kill(9, pid)
    Process.wait(pid)
  end
end
