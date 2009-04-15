# Copyright (c) 2009 Eric Wong
require 'test/test_helper'

do_test = true
$unicorn_bin = ENV['UNICORN_TEST_BIN'] || "unicorn"
redirect_test_io do
  do_test = system($unicorn_bin, '-v')
end

unless do_test
  warn "#{$unicorn_bin} not found in PATH=#{ENV['PATH']}, " \
       "skipping this test"
end

unless try_require('rack')
  warn "Unable to load Rack, skipping this test"
  do_test = false
end

class ExecTest < Test::Unit::TestCase
  trap(:QUIT, 'IGNORE')

  HI = <<-EOS
use Rack::ContentLength
run proc { |env| [ 200, { 'Content-Type' => 'text/plain' }, [ "HI\\n" ] ] }
  EOS

  HELLO = <<-EOS
class Hello
  def call(env)
    [ 200, { 'Content-Type' => 'text/plain' }, [ "HI\\n" ] ]
  end
end
  EOS

  COMMON_TMP = Tempfile.new('unicorn_tmp') unless defined?(COMMON_TMP)

  HEAVY_CFG = <<-EOS
worker_processes 4
timeout 30
logger Logger.new('#{COMMON_TMP.path}')
before_fork do |server, worker|
  server.logger.info "before_fork: worker=\#{worker.nr}"
end
  EOS

  def setup
    @pwd = Dir.pwd
    @tmpfile = Tempfile.new('unicorn_exec_test')
    @tmpdir = @tmpfile.path
    @tmpfile.close!
    Dir.mkdir(@tmpdir)
    Dir.chdir(@tmpdir)
    @addr = ENV['UNICORN_TEST_ADDR'] || '127.0.0.1'
    @port = unused_port(@addr)
    @sockets = []
    @start_pid = $$
  end

  def teardown
    return if @start_pid != $$
    Dir.chdir(@pwd)
    FileUtils.rmtree(@tmpdir)
    @sockets.each { |path| File.unlink(path) rescue nil }
    loop do
      Process.kill('-QUIT', 0)
      begin
        Process.waitpid(-1, Process::WNOHANG) or break
      rescue Errno::ECHILD
        break
      end
    end
  end

  def test_exit_signals
    %w(INT TERM QUIT).each do |sig|
      File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
      pid = xfork { redirect_test_io { exec($unicorn_bin, "-l#@addr:#@port") } }
      wait_master_ready("test_stderr.#{pid}.log")
      status = nil
      assert_nothing_raised do
        Process.kill(sig, pid)
        pid, status = Process.waitpid2(pid)
      end
      reaped = File.readlines("test_stderr.#{pid}.log").grep(/reaped/)
      assert_equal 1, reaped.size
      assert status.exited?
    end
  end

  def test_basic
    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    pid = fork do
      redirect_test_io { exec($unicorn_bin, "-l", "#{@addr}:#{@port}") }
    end
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class
    assert_shutdown(pid)
  end

  def test_help
    redirect_test_io do
      assert(system($unicorn_bin, "-h"), "help text returns true")
    end
    assert_equal 0, File.stat("test_stderr.#$$.log").size
    assert_not_equal 0, File.stat("test_stdout.#$$.log").size
    lines = File.readlines("test_stdout.#$$.log")

    # Be considerate of the on-call technician working from their
    # mobile phone or netbook on a slow connection :)
    assert lines.size <= 24, "help height fits in an ANSI terminal window"
    lines.each do |line|
      assert line.size <= 80, "help width fits in an ANSI terminal window"
    end
  end

  def test_broken_reexec_config
    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    pid_file = "#{@tmpdir}/test.pid"
    old_file = "#{pid_file}.oldbin"
    ucfg = Tempfile.new('unicorn_test_config')
    ucfg.syswrite("listen %(#@addr:#@port)\n")
    ucfg.syswrite("pid %(#{pid_file})\n")
    ucfg.syswrite("logger Logger.new(%(#{@tmpdir}/log))\n")
    pid = xfork do
      redirect_test_io do
        exec($unicorn_bin, "-D", "-l#{@addr}:#{@port}", "-c#{ucfg.path}")
      end
    end
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class

    wait_for_file(pid_file)
    Process.waitpid(pid)
    Process.kill(:USR2, File.read(pid_file).to_i)
    wait_for_file(old_file)
    wait_for_file(pid_file)
    old_pid = File.read(old_file).to_i
    Process.kill(:QUIT, old_pid)
    wait_for_death(old_pid)

    ucfg.syswrite("timeout %(#{pid_file})\n") # introduce a bug
    current_pid = File.read(pid_file).to_i
    Process.kill(:USR2, current_pid)

    # wait for pid_file to restore itself
    tries = DEFAULT_TRIES
    begin
      while current_pid != File.read(pid_file).to_i
        sleep(DEFAULT_RES) and (tries -= 1) > 0
      end
    rescue Errno::ENOENT
      (sleep(DEFAULT_RES) and (tries -= 1) > 0) and retry
    end
    assert_equal current_pid, File.read(pid_file).to_i

    tries = DEFAULT_TRIES
    while File.exist?(old_file)
      (sleep(DEFAULT_RES) and (tries -= 1) > 0) or break
    end
    assert ! File.exist?(old_file), "oldbin=#{old_file} gone"
    port2 = unused_port(@addr)

    # fix the bug
    ucfg.sysseek(0)
    ucfg.truncate(0)
    ucfg.syswrite("listen %(#@addr:#@port)\n")
    ucfg.syswrite("listen %(#@addr:#{port2})\n")
    ucfg.syswrite("pid %(#{pid_file})\n")
    assert_nothing_raised { Process.kill(:USR2, current_pid) }

    wait_for_file(old_file)
    wait_for_file(pid_file)
    new_pid = File.read(pid_file).to_i
    assert_not_equal current_pid, new_pid
    assert_equal current_pid, File.read(old_file).to_i
    results = retry_hit(["http://#{@addr}:#{@port}/",
                         "http://#{@addr}:#{port2}/"])
    assert_equal String, results[0].class
    assert_equal String, results[1].class

    assert_nothing_raised do
      Process.kill(:QUIT, current_pid)
      Process.kill(:QUIT, new_pid)
    end
  end

  def test_broken_reexec_ru
    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    pid_file = "#{@tmpdir}/test.pid"
    old_file = "#{pid_file}.oldbin"
    ucfg = Tempfile.new('unicorn_test_config')
    ucfg.syswrite("pid %(#{pid_file})\n")
    ucfg.syswrite("logger Logger.new(%(#{@tmpdir}/log))\n")
    pid = xfork do
      redirect_test_io do
        exec($unicorn_bin, "-D", "-l#{@addr}:#{@port}", "-c#{ucfg.path}")
      end
    end
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class

    wait_for_file(pid_file)
    Process.waitpid(pid)
    Process.kill(:USR2, File.read(pid_file).to_i)
    wait_for_file(old_file)
    wait_for_file(pid_file)
    old_pid = File.read(old_file).to_i
    Process.kill(:QUIT, old_pid)
    wait_for_death(old_pid)

    File.unlink("config.ru") # break reloading
    current_pid = File.read(pid_file).to_i
    Process.kill(:USR2, current_pid)

    # wait for pid_file to restore itself
    tries = DEFAULT_TRIES
    begin
      while current_pid != File.read(pid_file).to_i
        sleep(DEFAULT_RES) and (tries -= 1) > 0
      end
    rescue Errno::ENOENT
      (sleep(DEFAULT_RES) and (tries -= 1) > 0) and retry
    end

    tries = DEFAULT_TRIES
    while File.exist?(old_file)
      (sleep(DEFAULT_RES) and (tries -= 1) > 0) or break
    end
    assert ! File.exist?(old_file), "oldbin=#{old_file} gone"
    assert_equal current_pid, File.read(pid_file).to_i

    # fix the bug
    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    assert_nothing_raised { Process.kill(:USR2, current_pid) }
    wait_for_file(old_file)
    wait_for_file(pid_file)
    new_pid = File.read(pid_file).to_i
    assert_not_equal current_pid, new_pid
    assert_equal current_pid, File.read(old_file).to_i
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class

    assert_nothing_raised do
      Process.kill(:QUIT, current_pid)
      Process.kill(:QUIT, new_pid)
    end
  end

  def test_unicorn_config_listener_swap
    port_cli = unused_port
    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    ucfg = Tempfile.new('unicorn_test_config')
    ucfg.syswrite("listen '#@addr:#@port'\n")
    pid = xfork do
      redirect_test_io do
        exec($unicorn_bin, "-c#{ucfg.path}", "-l#@addr:#{port_cli}")
      end
    end
    results = retry_hit(["http://#@addr:#{port_cli}/"])
    assert_equal String, results[0].class
    results = retry_hit(["http://#@addr:#@port/"])
    assert_equal String, results[0].class

    port2 = unused_port(@addr)
    ucfg.sysseek(0)
    ucfg.truncate(0)
    ucfg.syswrite("listen '#@addr:#{port2}'\n")
    Process.kill(:HUP, pid)

    results = retry_hit(["http://#@addr:#{port2}/"])
    assert_equal String, results[0].class
    results = retry_hit(["http://#@addr:#{port_cli}/"])
    assert_equal String, results[0].class
    assert_nothing_raised do
      reuse = TCPServer.new(@addr, @port)
      reuse.close
    end
    assert_shutdown(pid)
  end

  def test_unicorn_config_listen_with_options
    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    ucfg = Tempfile.new('unicorn_test_config')
    ucfg.syswrite("listen '#{@addr}:#{@port}', :backlog => 512,\n")
    ucfg.syswrite("                            :rcvbuf => 4096,\n")
    ucfg.syswrite("                            :sndbuf => 4096\n")
    pid = xfork do
      redirect_test_io { exec($unicorn_bin, "-c#{ucfg.path}") }
    end
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class
    assert_shutdown(pid)
  end

  def test_unicorn_config_per_worker_listen
    port2 = unused_port
    pid_spit = 'use Rack::ContentLength;' \
      'run proc { |e| [ 200, {"Content-Type"=>"text/plain"}, ["#$$\\n"] ] }'
    File.open("config.ru", "wb") { |fp| fp.syswrite(pid_spit) }
    tmp = Tempfile.new('test.socket')
    File.unlink(tmp.path)
    ucfg = Tempfile.new('unicorn_test_config')
    ucfg.syswrite("listen '#@addr:#@port'\n")
    ucfg.syswrite("before_fork { |s,w|\n")
    ucfg.syswrite("  s.listen('#{tmp.path}', :backlog => 5, :sndbuf => 8192)\n")
    ucfg.syswrite("  s.listen('#@addr:#{port2}', :rcvbuf => 8192)\n")
    ucfg.syswrite("\n}\n")
    pid = xfork do
      redirect_test_io { exec($unicorn_bin, "-c#{ucfg.path}") }
    end
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class
    worker_pid = results[0].to_i
    assert_not_equal pid, worker_pid
    s = UNIXSocket.new(tmp.path)
    s.syswrite("GET / HTTP/1.0\r\n\r\n")
    results = ''
    loop { results << s.sysread(4096) } rescue nil
    assert_nothing_raised { s.close }
    assert_equal worker_pid, results.split(/\r\n/).last.to_i
    results = hit(["http://#@addr:#{port2}/"])
    assert_equal String, results[0].class
    assert_equal worker_pid, results[0].to_i
    assert_shutdown(pid)
  end

  def test_unicorn_config_listen_augments_cli
    port2 = unused_port(@addr)
    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    ucfg = Tempfile.new('unicorn_test_config')
    ucfg.syswrite("listen '#{@addr}:#{@port}'\n")
    pid = xfork do
      redirect_test_io do
        exec($unicorn_bin, "-c#{ucfg.path}", "-l#{@addr}:#{port2}")
      end
    end
    uris = [@port, port2].map { |i| "http://#{@addr}:#{i}/" }
    results = retry_hit(uris)
    assert_equal results.size, uris.size
    assert_equal String, results[0].class
    assert_equal String, results[1].class
    assert_shutdown(pid)
  end

  def test_weird_config_settings
    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    ucfg = Tempfile.new('unicorn_test_config')
    ucfg.syswrite(HEAVY_CFG)
    pid = xfork do
      redirect_test_io do
        exec($unicorn_bin, "-c#{ucfg.path}", "-l#{@addr}:#{@port}")
      end
    end

    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class
    wait_master_ready(COMMON_TMP.path)
    wait_workers_ready(COMMON_TMP.path, 4)
    bf = File.readlines(COMMON_TMP.path).grep(/\bbefore_fork: worker=/)
    assert_equal 4, bf.size
    rotate = Tempfile.new('unicorn_rotate')
    assert_nothing_raised do
      File.rename(COMMON_TMP.path, rotate.path)
      Process.kill(:USR1, pid)
    end
    wait_for_file(COMMON_TMP.path)
    assert File.exist?(COMMON_TMP.path), "#{COMMON_TMP.path} exists"
    # USR1 should've been passed to all workers
    tries = DEFAULT_TRIES
    log = File.readlines(rotate.path)
    while (tries -= 1) > 0 &&
          log.grep(/reopening logs\.\.\./).size < 5
      sleep DEFAULT_RES
      log = File.readlines(rotate.path)
    end
    assert_equal 5, log.grep(/reopening logs\.\.\./).size
    assert_equal 0, log.grep(/done reopening logs/).size

    tries = DEFAULT_TRIES
    log = File.readlines(COMMON_TMP.path)
    while (tries -= 1) > 0 && log.grep(/done reopening logs/).size < 5
      sleep DEFAULT_RES
      log = File.readlines(COMMON_TMP.path)
    end
    assert_equal 5, log.grep(/done reopening logs/).size
    assert_equal 0, log.grep(/reopening logs\.\.\./).size
    assert_nothing_raised { Process.kill(:QUIT, pid) }
    status = nil
    assert_nothing_raised { pid, status = Process.waitpid2(pid) }
    assert status.success?, "exited successfully"
  end

  def test_read_embedded_cli_switches
    File.open("config.ru", "wb") do |fp|
      fp.syswrite("#\\ -p #{@port} -o #{@addr}\n")
      fp.syswrite(HI)
    end
    pid = fork { redirect_test_io { exec($unicorn_bin) } }
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class
    assert_shutdown(pid)
  end

  def test_config_ru_alt_path
    config_path = "#{@tmpdir}/foo.ru"
    File.open(config_path, "wb") { |fp| fp.syswrite(HI) }
    pid = fork do
      redirect_test_io do
        Dir.chdir("/")
        exec($unicorn_bin, "-l#{@addr}:#{@port}", config_path)
      end
    end
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class
    assert_shutdown(pid)
  end

  def test_load_module
    libdir = "#{@tmpdir}/lib"
    FileUtils.mkpath([ libdir ])
    config_path = "#{libdir}/hello.rb"
    File.open(config_path, "wb") { |fp| fp.syswrite(HELLO) }
    pid = fork do
      redirect_test_io do
        Dir.chdir("/")
        exec($unicorn_bin, "-l#{@addr}:#{@port}", config_path)
      end
    end
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class
    assert_shutdown(pid)
  end

  def test_reexec
    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    pid_file = "#{@tmpdir}/test.pid"
    pid = fork do
      redirect_test_io do
        exec($unicorn_bin, "-l#{@addr}:#{@port}", "-P#{pid_file}")
      end
    end
    reexec_basic_test(pid, pid_file)
  end

  def test_reexec_alt_config
    config_file = "#{@tmpdir}/foo.ru"
    File.open(config_file, "wb") { |fp| fp.syswrite(HI) }
    pid_file = "#{@tmpdir}/test.pid"
    pid = fork do
      redirect_test_io do
        exec($unicorn_bin, "-l#{@addr}:#{@port}", "-P#{pid_file}", config_file)
      end
    end
    reexec_basic_test(pid, pid_file)
  end

  def test_socket_unlinked_restore
    results = nil
    sock = Tempfile.new('unicorn_test_sock')
    sock_path = sock.path
    sock.close!
    ucfg = Tempfile.new('unicorn_test_config')
    ucfg.syswrite("listen \"#{sock_path}\"\n")

    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    pid = xfork { redirect_test_io { exec($unicorn_bin, "-c#{ucfg.path}") } }
    wait_for_file(sock_path)
    assert File.socket?(sock_path)
    assert_nothing_raised do
      sock = UNIXSocket.new(sock_path)
      sock.syswrite("GET / HTTP/1.0\r\n\r\n")
      results = sock.sysread(4096)
    end
    assert_equal String, results.class
    assert_nothing_raised do
      File.unlink(sock_path)
      Process.kill(:HUP, pid)
    end
    wait_for_file(sock_path)
    assert File.socket?(sock_path)
    assert_nothing_raised do
      sock = UNIXSocket.new(sock_path)
      sock.syswrite("GET / HTTP/1.0\r\n\r\n")
      results = sock.sysread(4096)
    end
    assert_equal String, results.class
  end

  def test_unicorn_config_file
    pid_file = "#{@tmpdir}/test.pid"
    sock = Tempfile.new('unicorn_test_sock')
    sock_path = sock.path
    sock.close!
    @sockets << sock_path

    log = Tempfile.new('unicorn_test_log')
    ucfg = Tempfile.new('unicorn_test_config')
    ucfg.syswrite("listen \"#{sock_path}\"\n")
    ucfg.syswrite("pid \"#{pid_file}\"\n")
    ucfg.syswrite("logger Logger.new('#{log.path}')\n")
    ucfg.close

    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    pid = xfork do
      redirect_test_io do
        exec($unicorn_bin, "-l#{@addr}:#{@port}",
             "-P#{pid_file}", "-c#{ucfg.path}")
      end
    end
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class
    wait_master_ready(log.path)
    assert File.exist?(pid_file), "pid_file created"
    assert_equal pid, File.read(pid_file).to_i
    assert File.socket?(sock_path), "socket created"
    assert_nothing_raised do
      sock = UNIXSocket.new(sock_path)
      sock.syswrite("GET / HTTP/1.0\r\n\r\n")
      results = sock.sysread(4096)
    end
    assert_equal String, results.class

    # try reloading the config
    sock = Tempfile.new('new_test_sock')
    new_sock_path = sock.path
    @sockets << new_sock_path
    sock.close!
    new_log = Tempfile.new('unicorn_test_log')
    new_log.sync = true
    assert_equal 0, new_log.size

    assert_nothing_raised do
      ucfg = File.open(ucfg.path, "wb")
      ucfg.syswrite("listen \"#{sock_path}\"\n")
      ucfg.syswrite("listen \"#{new_sock_path}\"\n")
      ucfg.syswrite("pid \"#{pid_file}\"\n")
      ucfg.syswrite("logger Logger.new('#{new_log.path}')\n")
      ucfg.close
      Process.kill(:HUP, pid)
    end

    wait_for_file(new_sock_path)
    assert File.socket?(new_sock_path), "socket exists"
    @sockets.each do |path|
      assert_nothing_raised do
        sock = UNIXSocket.new(path)
        sock.syswrite("GET / HTTP/1.0\r\n\r\n")
        results = sock.sysread(4096)
      end
      assert_equal String, results.class
    end

    assert_not_equal 0, new_log.size
    reexec_usr2_quit_test(pid, pid_file)
  end

  def test_daemonize_reexec
    pid_file = "#{@tmpdir}/test.pid"
    log = Tempfile.new('unicorn_test_log')
    ucfg = Tempfile.new('unicorn_test_config')
    ucfg.syswrite("pid \"#{pid_file}\"\n")
    ucfg.syswrite("logger Logger.new('#{log.path}')\n")
    ucfg.close

    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    pid = xfork do
      redirect_test_io do
        exec($unicorn_bin, "-D", "-l#{@addr}:#{@port}", "-c#{ucfg.path}")
      end
    end
    results = retry_hit(["http://#{@addr}:#{@port}/"])
    assert_equal String, results[0].class
    wait_for_file(pid_file)
    new_pid = File.read(pid_file).to_i
    assert_not_equal pid, new_pid
    pid, status = Process.waitpid2(pid)
    assert status.success?, "original process exited successfully"
    assert_nothing_raised { Process.kill(0, new_pid) }
    reexec_usr2_quit_test(new_pid, pid_file)
  end

  def test_reexec_fd_leak
    unless RUBY_PLATFORM =~ /linux/ # Solaris may work, too, but I forget...
      warn "FD leak test only works on Linux at the moment"
      return
    end
    pid_file = "#{@tmpdir}/test.pid"
    log = Tempfile.new('unicorn_test_log')
    log.sync = true
    ucfg = Tempfile.new('unicorn_test_config')
    ucfg.syswrite("pid \"#{pid_file}\"\n")
    ucfg.syswrite("logger Logger.new('#{log.path}')\n")
    ucfg.syswrite("stderr_path '#{log.path}'\n")
    ucfg.syswrite("stdout_path '#{log.path}'\n")
    ucfg.close

    File.open("config.ru", "wb") { |fp| fp.syswrite(HI) }
    pid = xfork do
      redirect_test_io do
        exec($unicorn_bin, "-D", "-l#{@addr}:#{@port}", "-c#{ucfg.path}")
      end
    end

    wait_master_ready(log.path)
    File.truncate(log.path, 0)
    wait_for_file(pid_file)
    orig_pid = pid = File.read(pid_file).to_i
    orig_fds = `ls -l /proc/#{pid}/fd`.split(/\n/)
    assert $?.success?
    expect_size = orig_fds.size

    assert_nothing_raised do
      Process.kill(:USR2, pid)
      wait_for_file("#{pid_file}.oldbin")
      Process.kill(:QUIT, pid)
    end
    wait_for_death(pid)

    wait_master_ready(log.path)
    File.truncate(log.path, 0)
    wait_for_file(pid_file)
    pid = File.read(pid_file).to_i
    assert_not_equal orig_pid, pid
    curr_fds = `ls -l /proc/#{pid}/fd`.split(/\n/)
    assert $?.success?

    # we could've inherited descriptors the first time around
    assert expect_size >= curr_fds.size, curr_fds.inspect
    expect_size = curr_fds.size

    assert_nothing_raised do
      Process.kill(:USR2, pid)
      wait_for_file("#{pid_file}.oldbin")
      Process.kill(:QUIT, pid)
    end
    wait_for_death(pid)

    wait_master_ready(log.path)
    File.truncate(log.path, 0)
    wait_for_file(pid_file)
    pid = File.read(pid_file).to_i
    curr_fds = `ls -l /proc/#{pid}/fd`.split(/\n/)
    assert $?.success?
    assert_equal expect_size, curr_fds.size, curr_fds.inspect

    Process.kill(:QUIT, pid)
    wait_for_death(pid)
  end

end if do_test
